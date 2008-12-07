require File.dirname(__FILE__) + '/../spec_helper'

describe Cardname, "to_key" do
  it "should remove spaces" do
    "This Name".to_key.should == "this_name"
  end
  
  it "should singularize" do
    "ethans".to_key.should == "ethan"
  end                               
  
  it "should underscore" do 
    "ThisThing".to_key.should == "this_thing"
  end
  
  it "should handle plus cards" do
    "ThisThing+Ethans".to_key.should == "this_thing+ethan"
  end          
  
  it "should retain * for star cards" do
    "*rform".to_key.should == "*rform"
  end
end

