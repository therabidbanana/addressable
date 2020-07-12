# frozen_string_literal: true

# coding: utf-8
# Copyright (C) Bob Aman
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
require "spec_helper"

require "bigdecimal"
require "addressable/template_machine"

def tagged(name, value)
  Addressable::TemplateMachine::TaggedValue.new(name, value)
end

context "valid TemplateMachine::Variable(explode: false)" do
  let(:name) { "foo" }

  let(:op) { Addressable::TemplateMachine::OpPlain }
  subject {
    Addressable::TemplateMachine::Variable.new(op: op, name: name)
  }

  it "normalizes simple types" do
    expect(subject.expand_with(true)).to contain_exactly(name, "true")
    expect(subject.expand_with(false)).to contain_exactly(name, "false")
    expect(subject.expand_with(42)).to contain_exactly(name, "42")
    expect(subject.expand_with(:string)).to contain_exactly(name, "string")
  end

  it "does percent encoding for strings with reserved characters" do
    expect(subject.expand_with("hello world!")).to contain_exactly(name, "hello%20world%21")
  end

  it "can do a combination of normalize and join" do
    expect(subject.expand_with(["a", "b", "hello world!"])).to contain_exactly(name, "a,b,hello%20world%21")
    expect(subject.expand_with({"foo" => "bar", "baz" => "qux"})).to contain_exactly(name, "foo,bar,baz,qux")
  end
end

context "valid TemplateMachine::Variable(explode: true)" do
  let(:op) { Addressable::TemplateMachine::OpPlain }
  let(:name) { "foo" }
  subject {
    Addressable::TemplateMachine::Variable.new(op: op, name: name, explode: true)
  }

  it "normalizes simple types" do
    expect(subject.expand_with(true)).to contain_exactly(name, "true")
    expect(subject.expand_with(false)).to contain_exactly(name, "false")
    expect(subject.expand_with(42)).to contain_exactly(name, "42")
    expect(subject.expand_with(:string)).to contain_exactly(name, "string")
  end

  it "does percent encoding for strings with reserved characters" do
    expect(subject.expand_with("hello world!")).to contain_exactly(name, "hello%20world%21")
  end

  it "can do a combination of normalize and join" do
    expect(subject.expand_with(["a", "b", "hello world!"])).to contain_exactly(name, ["a","b","hello%20world%21"])
    expect(subject.expand_with({"foo" => "bar", "baz" => "qux"})).to contain_exactly(name, ["foo=bar","baz=qux"])
  end
end
