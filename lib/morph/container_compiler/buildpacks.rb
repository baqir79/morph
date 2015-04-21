module Morph
  module ContainerCompiler
    class Buildpacks < Base
      ALL_CONFIG_FILENAMES = ["Gemfile", "Gemfile.lock", "Procfile", "requirements.txt", "runtime.txt", "composer.json", "composer.lock", "cpanfile"]

      def self.compile_and_run(run)
        wrapper = Multiblock.wrapper
        yield(wrapper)

        i1 = compile(run.repo_path) do |on|
          on.log {|s,c| wrapper.call(:log, s, c)}
        end

        # If something went wrong during the compile and it couldn't finish
        if i1.nil?
          # TODO: Return the status for a compile error
          return 255;
        end

        # Insert the actual code into the container
        wrapper.call(:log, :internalout, "Injecting scraper code...\n")
        i2 = docker_build_command(i1, "add code.tar /app",
          "code.tar" => tar_run_files(run.repo_path)) do |on|
          # Note that we're not sending the output of this to the console
          # because it is relatively short running and is otherwise confusing
        end

        command = Metric.command("/start scraper", "/data/" + Run.time_output_filename)
        # Handle this run not having a scraper attached (run from morph-cli)
        if run.scraper
          env_variables = run.scraper.variables.map{|v| [v.name, v.value]}
        else
          env_variables = []
        end

        status_code = Morph::DockerRunner.run(
          command: command,
          # TODO Need to run this as the user scraper again
          user: "root",
          image_name: i2.id,
          container_name: run.docker_container_name,
          data_path: run.data_path,
          env_variables: env_variables
        ) do |on|
            on.log { |s,c| wrapper.call(:log, s, c)}
            on.ip_address {|ip| wrapper.call(:ip_address, ip)}
        end

        i2.delete("noprune" => 1)
        status_code
      end

      # Currently this will only stop the main run of the scraper. It won't
      # actually stop the compile stage
      # TODO Make this stop the compile stage
      def self.stop(run)
        Morph::DockerRunner.stop(docker_container_name(run))
      end

      # file_environment needs to also include a Dockerfile with content
      def self.docker_build_from_files(file_environment)
        wrapper = Multiblock.wrapper
        yield(wrapper)

        result = nil
        dir = Dir.mktmpdir("morph")
        begin
          file_environment.each do |file, content|
            path = File.join(dir, file)
            File.open(path, "w") {|f| f.write content}
            # Set an arbitrary & fixed modification time on the files so that if
            # content is the same it will cache
            FileUtils.touch(path, mtime: Time.new(2000,1,1))
          end
          conn_interactive = Docker::Connection.new(ENV["DOCKER_URL"] || Docker.default_socket_url, {read_timeout: 4.hours})
          begin
            result = Docker::Image.build_from_dir(dir, {'rm' => 1}, conn_interactive) do |chunk|
              # TODO Do this properly
              begin
                wrapper.call(:log, :stdout, JSON.parse(chunk)["stream"])
              rescue JSON::ParserError
                # Workaround until we handle this properly
              end
            end
          rescue Docker::Error::UnexpectedResponseError
            result = nil
          end
        ensure
          FileUtils.remove_entry_secure dir
        end
        result
      end

      # file_environment is a hash of files (and their contents) to put in the same directory
      # as the Dockerfile created to contain the command
      # Returns the new image
      def self.docker_build_command(image, commands, file_environment)
        wrapper = Multiblock.wrapper
        yield(wrapper)

        commands = [commands] unless commands.kind_of?(Array)

        file_environment["Dockerfile"] = "from #{image.id}\n" + commands.map{|c| c + "\n"}.join
        docker_build_from_files(file_environment) do |on|
          on.log {|s,c| wrapper.call(:log, s, c)}
        end
      end

      def self.compile(repo_path)
        wrapper = Multiblock.wrapper
        yield(wrapper)

        i = get_or_pull_image('openaustralia/buildstep') do |on|
          on.log {|s,c| wrapper.call(:log, :internalout, c)}
        end
        # Insert the configuration part of the application code into the container
        wrapper.call(:log, :internalout, "Injecting configuration...\n")
        i2 = docker_build_command(i,
          ["ADD code_config.tar /app"],
          "code_config.tar" => tar_config_files(repo_path)) do |on|
        end
        # And build
        docker_build_command(i2,
          ["ENV CURL_TIMEOUT 180", "RUN /build/builder"], {}) do |on|
          on.log {|s,c| wrapper.call(:log, :internalout, c)}
        end
      end

      # Contents of a tarfile that contains configuration type files
      # like Gemfile, requirements.txt, etc..
      # This comes from a whitelisted list
      def self.tar_config_files(repo_path)
        Dir.mktmpdir("morph") do |dir|
          write_all_config_with_defaults_to_directory(File.join(Rails.root, repo_path), dir)
          create_tar(dir)
        end
      end

      # Contents of a tarfile that contains everything that isn't a configuration file
      def self.tar_run_files(source)
        Dir.mktmpdir("morph") do |dest|
          write_all_run_to_directory(source, dest)
          create_tar(dest)
        end
      end

      def self.add_config_defaults_to_directory(dest, language)
        language.default_files_to_insert.each do |files|
          if files.all?{|file| !File.exists?(File.join(dest, file))}
            files.each do |file|
              FileUtils.cp(language.default_config_file_path(file), File.join(dest, file))
            end
          end
        end

        # Special behaviour for Procfile. We don't allow the user to override this
        FileUtils.cp(language.default_config_file_path("Procfile"), File.join(dest, "Procfile"))
      end

      def self.write_all_config_with_defaults_to_directory(source, dest)
        ALL_CONFIG_FILENAMES.each do |config_filename|
          path = File.join(source, config_filename)
          FileUtils.cp(path, dest) if File.exists?(path)
        end

        # We don't need to check that the language is recognised because
        # the compiler is never called if the language isn't valid
        add_config_defaults_to_directory(dest, Morph::Language.language(source))

        fix_modification_times(dest)
      end

      def self.write_all_run_to_directory(source, dest)
        FileUtils.cp_r File.join(source, "."), dest

        ALL_CONFIG_FILENAMES.each do |path|
          FileUtils.rm_f(File.join(dest, path))
        end

        remove_hidden_directories(dest)

        # TODO I don't think I need to this step here
        fix_modification_times(dest)
      end

      # Remove directories starting with "."
      # TODO Make it just remove the .git directory in the root and not other hidden directories
      # which people might find useful
      def self.remove_hidden_directories(directory)
        Find.find(directory) do |path|
          FileUtils.rm_rf(path) if FileTest.directory?(path) && File.basename(path)[0] == ?.
        end
      end

      # Set an arbitrary & fixed modification time on everything in a directory
      # This ensures that if the content is the same docker will cache
      def self.fix_modification_times(dir)
        Find.find(dir) do |entry|
          FileUtils.touch(entry, mtime: Time.new(2000,1,1))
        end
      end

      def self.create_tar(directory)
        tempfile = Tempfile.new('morph_tar')

        in_directory(directory) do
          # We used to use Archive::Tar::Minitar but that doesn't support
          # symbolic links in the tar file. So, using tar from the command line
          # instead.
          `tar cf #{tempfile.path} .`
        end
        content = File.read(tempfile.path)
        FileUtils.rm_f(tempfile.path)
        content
      end

      def self.in_directory(directory)
        cwd = FileUtils.pwd
        FileUtils.cd(directory)
        yield
      ensure
        FileUtils.cd(cwd)
      end
    end
  end
end
