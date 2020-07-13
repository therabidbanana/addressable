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

context "valid TemplateMachine::Variable(explode: false)" do
  let(:name) { "foo" }

  let(:op) { Addressable::TemplateMachine::OpPlain }
  subject {
    Addressable::TemplateMachine::Variable.new(op: op, name: name)
  }

  context '#expand_with(value)' do
    it "normalizes simple types" do
      expect(subject.expand_with(true)).to include(name, "true")
      expect(subject.expand_with(false)).to include(name, "false")
      expect(subject.expand_with(42)).to include(name, "42")
      expect(subject.expand_with(:string)).to include(name, "string")
    end

    it "does percent encoding for strings with reserved characters" do
      expect(subject.expand_with("hello world!")).to include(name, "hello%20world%21")
    end

    it "can do a combination of normalize and join" do
      expect(subject.expand_with(["a", "b", "hello world!"])).to include(name, "a,b,hello%20world%21")
      expect(subject.expand_with({"foo" => "bar", "baz" => "qux"})).to include(name, "foo,bar,baz,qux")
    end
  end

end

context "valid TemplateMachine::Variable(explode: true)" do
  let(:op) { Addressable::TemplateMachine::OpPlain }
  let(:name) { "foo" }
  subject {
    Addressable::TemplateMachine::Variable.new(op: op, name: name, explode: true)
  }

  it "normalizes simple types" do
    expect(subject.expand_with(true)).to contain_exactly(name, "true", nil)
    expect(subject.expand_with(false)).to contain_exactly(name, "false", nil)
    expect(subject.expand_with(42)).to contain_exactly(name, "42", nil)
    expect(subject.expand_with(:string)).to contain_exactly(name, "string", nil)
  end

  it "does percent encoding for strings with reserved characters" do
    expect(subject.expand_with("hello world!")).to contain_exactly(name, "hello%20world%21", nil)
  end

  it "can do a combination of normalize and join" do
    expect(subject.expand_with(["a", "b", "hello world!"])).to contain_exactly(name, ["a","b","hello%20world%21"], nil)
    expect(subject.expand_with({"foo" => "bar", "baz" => "qux"})).to contain_exactly(name, ["foo=bar","baz=qux"], true)
  end
end

context "Addressable::TemplateMachine::OpPath" do
  let(:name) { "foo" }
  let(:var) { Addressable::TemplateMachine::Variable.new(op: op, name: name, explode: true) }

  subject(:op) { Addressable::TemplateMachine::OpPath }

  context '#extract_with(scanner)' do
    it "normalizes simple types" do
      expect(subject.extract_values("/true", {}, [var])).to include(name => "true")
      expect(subject.extract_values("/false", {}, [var])).to include(name => "false")
      expect(subject.extract_values("/42", {}, [var])).to include(name => "42")
      expect(subject.extract_values("/string", {}, [var])).to include(name => "string")
    end

    it "does percent encoding for strings with reserved characters" do
      expect(subject.extract_values("/hello%20world%21", {}, [var])).to include(name => "hello world!")
    end

    it "detects empty string" do
      expect(subject.extract_values("/", {}, [var])).to include(name => "")
    end

    it "detects undefined" do
      expect(subject.extract_values("", {}, [var])).to include(name => nil)
    end

    it "can do a combination of normalize and join" do
      expect(subject.extract_values("/a/b/hello%20world%21", {}, [var])).to include(name => ["a", "b", "hello world!"])
      expect(subject.extract_values("/foo=bar/baz=qux", {}, [var])).to include(name => {"foo" => "bar", "baz" => "qux"})
    end
  end
end
