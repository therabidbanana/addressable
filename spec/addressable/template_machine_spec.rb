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
require "addressable/template"

describe Addressable::Template::Values do
  def lookup(mapping, normalize_values = true)
    Addressable::Template::Values.new(mapping, normalize_values)
  end

  it "takes a mapping with symbol keys" do
    expect(lookup(a: "x")["a"]).to eq("x")
  end

  it "takes an array of name and value pairs" do
    expect(lookup([["a", "x"]])["a"]).to eq("x")
  end

  it "takes a lambda" do
    expect(lookup(lambda { |name| name.upcase })["a"]).to eq("A")
  end

  it "raises TypeError for a mapping it can't read" do
    expect { lookup("a") }.to raise_error(
      TypeError, "Can't convert String into a mapping."
    )
  end

  it "converts numbers, symbols and booleans to strings" do
    values = lookup(
      "i" => 42, "f" => 1.5, "d" => BigDecimal("2"), "s" => :sym,
      "t" => true, "n" => false
    )
    expect(values["i"]).to eq("42")
    expect(values["f"]).to eq("1.5")
    expect(values["d"]).to eq(BigDecimal("2").to_s)
    expect(values["s"]).to eq("sym")
    expect(values["t"]).to eq("true")
    expect(values["n"]).to eq("false")
  end

  it "raises TypeError for a value that isn't a string, list or hash" do
    expect { lookup("a" => Object.new)["a"] }.to raise_error(
      TypeError, "Can't convert Object into String or Array."
    )
  end

  it "gives nil for a missing variable" do
    expect(lookup({})["a"]).to be_nil
  end

  it "gives nil for nil, an empty list and an empty hash" do
    values = lookup("n" => nil, "l" => [], "h" => {})
    expect(values["n"]).to be_nil
    expect(values["l"]).to be_nil
    expect(values["h"]).to be_nil
  end

  it "drops nil members, and gives nil when only nil members were left" do
    values = lookup(
      "l" => [nil, "a", nil], "h" => {"a" => nil, "b" => "c"},
      "ln" => [nil], "hn" => {"a" => nil}
    )
    expect(values["l"]).to eq(["a"])
    expect(values["h"]).to eq("b" => "c")
    expect(values["ln"]).to be_nil
    expect(values["hn"]).to be_nil
  end

  it "reads a list from any object with to_ary" do
    list = Struct.new(:to_ary).new(["a", nil, "b"])
    expect(lookup("l" => list)["l"]).to eq(["a", "b"])
  end

  it "normalizes values, list members, and hash keys and values to NFC" do
    values = lookup(
      "s" => "é", "l" => ["é"], "h" => {"é" => "é"}
    )
    expect(values["s"]).to eq("é")
    expect(values["l"]).to eq(["é"])
    expect(values["h"]).to eq("é" => "é")
  end

  it "leaves values as they are when normalize_values is false" do
    values = lookup({"s" => "é", "i" => 42}, false)
    expect(values["s"]).to eq("é")
    expect(values["i"]).to eq("42")
  end

  it "keeps the bytes of a value that isn't valid UTF-8" do
    value = lookup("a" => "caf\xE9".b)["a"]
    expect(value.encoding).to eq(Encoding::UTF_8)
    expect(value.bytes).to eq("caf\xE9".b.bytes)
  end

  it "prepares each name once" do
    values = lookup("a" => "é")
    expect(Addressable::Template::Values).to receive(:defined_value).
      twice.and_call_original
    expect(Addressable::Template::Values).to receive(:normalize_value).
      once.and_call_original
    first = values["a"]
    expect(values["a"]).to equal(first)
    expect(values["b"]).to be_nil
    expect(values["b"]).to be_nil
  end
end

describe Addressable::Template, "with the :machine engine, #expand" do
  def expand(pattern, *args)
    Addressable::Template.new(pattern, engine: :machine).expand(*args).to_str
  end

  it "leaves values unnormalized when normalize_values is false" do
    expect(expand("{a}", {"a" => "é"}, nil, false)).to eq("e%CC%81")
    expect(expand("{a}", {"a" => "é"})).to eq("%C3%A9")
  end

  it "looks up a variable used twice once" do
    calls = 0
    mapping = lambda { |name| calls += 1; name.upcase }
    expect(expand("{a}{+a}", mapping)).to eq("AA")
    expect(calls).to eq(1)
  end

  it "drops nil members of lists and hashes" do
    expect(expand("{a}", "a" => [nil, "x", nil])).to eq("x")
    expect(expand("{?a*}", "a" => {"b" => nil, "c" => "d"})).to eq("?c=d")
    expect(expand("{?a}", "a" => [nil])).to eq("")
  end
end

context "valid Template::Machine::Variable(explode: false)" do
  let(:name) { "foo" }

  let(:op) { Addressable::Template::Machine::OpPlain }
  subject {
    Addressable::Template::Machine::Variable.new(op: op, name: name)
  }

  context '#expand_with(value)' do
    it "gives nil for an undefined value" do
      expect(subject.expand_with(nil)).to be_nil
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

context "valid Template::Machine::Variable(explode: true)" do
  let(:op) { Addressable::Template::Machine::OpPlain }
  let(:name) { "foo" }
  subject {
    Addressable::Template::Machine::Variable.new(op: op, name: name, explode: true)
  }

  it "does percent encoding for strings with reserved characters" do
    expect(subject.expand_with("hello world!")).to contain_exactly(name, "hello%20world%21", nil)
  end

  it "can do a combination of normalize and join" do
    expect(subject.expand_with(["a", "b", "hello world!"])).to contain_exactly(name, ["a","b","hello%20world%21"], nil)
    expect(subject.expand_with({"foo" => "bar", "baz" => "qux"})).to contain_exactly(name, ["foo=bar","baz=qux"], true)
  end
end

context "Addressable::Template::Machine::OpPath" do
  let(:name) { "foo" }
  let(:var) {
    Addressable::Template::Machine::Variable.new(
      op: Addressable::Template::Machine::OpPath, name: name, explode: true
    )
  }

  subject { Addressable::Template::Machine::OpPath.new([var]) }

  context '#extract_values(scanner, matches)' do
    it "normalizes simple types" do
      expect(subject.extract_values("/true", {})).to include(name => "true")
      expect(subject.extract_values("/false", {})).to include(name => "false")
      expect(subject.extract_values("/42", {})).to include(name => "42")
      expect(subject.extract_values("/string", {})).to include(name => "string")
    end

    it "does percent encoding for strings with reserved characters" do
      expect(subject.extract_values("/hello%20world%21", {})).to include(name => "hello world!")
    end

    it "detects empty string" do
      pending "the phase 3 matcher; extract_values sets nothing for an empty segment"
      expect(subject.extract_values("/", {})).to include(name => [""])
    end

    it "detects undefined" do
      expect(subject.extract_values("", {})).to include(name => nil)
    end

    it "can do a combination of normalize and join" do
      expect(subject.extract_values("/a/b/hello%20world%21", {})).to include(name => ["a", "b", "hello world!"])
      expect(subject.extract_values("/foo=bar/baz=qux", {})).to include(name => {"foo" => "bar", "baz" => "qux"})
    end
  end
end
