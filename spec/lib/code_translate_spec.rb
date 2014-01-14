require 'spec_helper'

describe CodeTranslate do
  describe ".ruby" do
    it "should not change anything if scraperwiki is already included (with single quotes)" do
      CodeTranslate.ruby("require 'scraperwiki'\nsome other code\n").should ==
        "require 'scraperwiki'\nsome other code\n"
    end

    it "should not change anything if scraperwiki is already included (with double quotes)" do
      CodeTranslate.ruby("require \"scraperwiki\"\nsome other code\n").should ==
        "require \"scraperwiki\"\nsome other code\n"
    end

    it "should add the require if it's not there" do
      CodeTranslate.ruby("some code\n").should ==
        "require 'scraperwiki'\nsome code\n"
    end
  end
end
