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

  context "with a processor" do
    def processor(methods)
      calls = @calls = []
      object = Object.new
      methods.each do |method_name, result|
        object.define_singleton_method(method_name) do |name, value|
          calls << [method_name, name, value]
          result
        end
      end
      object
    end

    def with(methods, normalize_values = true)
      Addressable::Template::Values.new({}, normalize_values, processor(methods))
    end

    it "validates nothing without a processor" do
      expect(lookup({}).validate("a", "x")).to be_nil
    end

    it "validates nothing with a processor that doesn't validate" do
      expect(with(transform: "y").validate("a", "x")).to be_nil
      expect(@calls).to eq([])
    end

    it "gives validate the name and value" do
      with(validate: true).validate("a", "x")
      expect(@calls).to eq([[:validate, "a", "x"]])
    end

    it "raises InvalidTemplateValueError for a value that doesn't validate" do
      expect { with(validate: false).validate("a", "x") }.to raise_error(
        Addressable::Template::InvalidTemplateValueError,
        "a=x is an invalid template value."
      )
    end

    it "shows a list that doesn't validate with inspect" do
      expect { with(validate: nil).validate("a", ["x", "y"]) }.to raise_error(
        Addressable::Template::InvalidTemplateValueError,
        "a=#{["x", "y"].inspect} is an invalid template value."
      )
    end

    it "transforms only with a processor that has transform" do
      expect(lookup({}).transforms?).to be false
      expect(with(validate: true).transforms?).to be false
      expect(with(transform: "y").transforms?).to be true
    end

    it "gives transform the name and value and normalizes its result" do
      expect(with(transform: "é").transform("a", "x")).to eq("é")
      expect(@calls).to eq([[:transform, "a", "x"]])
    end

    it "doesn't normalize a transform result when normalize_values is false" do
      expect(with({transform: "é"}, false).transform("a", "x")).
        to eq("é")
    end

    it "calls the processor each time, without caching" do
      values = with(validate: true, transform: "y")
      2.times do
        values.validate("a", "x")
        values.transform("a", "x")
      end
      expect(@calls.size).to eq(4)
    end
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

  it "looks up variables with a block" do
    template = Addressable::Template.new("{a}{+a}{b}", engine: :machine)
    names = []
    result = template.expand { |name| names << name; name.upcase }
    expect(result.to_str).to eq("AAB")
    expect(names).to eq(["a", "b"])
  end

  it "takes a block with a nil mapping" do
    template = Addressable::Template.new("{a}", engine: :machine)
    expect(template.expand(nil) { |name| "x" }.to_str).to eq("x")
  end

  it "raises ArgumentError for both a mapping and a block" do
    template = Addressable::Template.new("{a}", engine: :machine)
    expect { template.expand({}) { |name| "x" } }.to raise_error(
      ArgumentError, "Pass a mapping or a block, not both."
    )
  end

  it "raises ArgumentError for neither a mapping nor a block" do
    template = Addressable::Template.new("{a}", engine: :machine)
    expect { template.expand }.to raise_error(
      ArgumentError, "A mapping or a block is required."
    )
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

  def expand(value)
    subject.expand_with(Addressable::Template::Values.new({name => value}, true))
  end

  context '#expand_with(values)' do
    it "gives nil for an undefined value" do
      expect(expand(nil)).to be_nil
    end

    it "does percent encoding for strings with reserved characters" do
      expect(expand("hello world!")).to include(name, "hello%20world%21")
    end

    it "can do a combination of normalize and join" do
      expect(expand(["a", "b", "hello world!"])).to include(name, "a,b,hello%20world%21")
      expect(expand({"foo" => "bar", "baz" => "qux"})).to include(name, "foo,bar,baz,qux")
    end
  end

end

describe Addressable::Template, "with the :machine engine, #expand with a processor" do
  # The result, or the error's class and message, and the processor's calls.
  def outcome(engine, pattern, mapping, processor_methods, normalize = true)
    calls = []
    processor = Object.new
    processor_methods.each do |method_name, body|
      processor.define_singleton_method(method_name) do |name, value|
        calls << [method_name, name, value]
        body.call(name, value)
      end
    end
    template = Addressable::Template.new(pattern, engine: engine)
    result = begin
      template.expand(mapping, processor, normalize).to_str
    rescue StandardError => error
      [error.class, error.message]
    end
    [result, calls]
  end

  def expect_same(pattern, mapping, processor_methods, normalize = true)
    expected = outcome(:regexp, pattern, mapping, processor_methods, normalize)
    expect(outcome(:machine, pattern, mapping, processor_methods, normalize)).
      to eq(expected)
  end

  upcase = {transform: lambda { |_name, value| value.upcase }}
  ["", "+", "#", "/", ".", ";", "?", "&"].each do |operator|
    it "transforms without encoding in {#{operator}a,b}" do
      expect_same("{#{operator}a,b}", {"a" => "x y/z", "b" => "w"}, upcase)
    end

    it "transforms an array result in {#{operator}a}" do
      expect_same("{#{operator}a}", {"a" => "x"},
        transform: lambda { |_name, _value| ["p q", "r"] })
    end

    it "transforms an exploded array result in {#{operator}a*}" do
      expect_same("{#{operator}a*}", {"a" => "x"},
        transform: lambda { |_name, _value| ["p", "r"] })
    end

    it "joins a transformed array of pairs in {#{operator}a}" do
      expect_same("{#{operator}a}", {"a" => "x"},
        transform: lambda { |_name, _value| ["p=1", "r=2"] })
    end

    it "transforms a list value in {#{operator}a}" do
      expect_same("{#{operator}a}", {"a" => ["x", "y"]},
        transform: lambda { |_name, value| value.map(&:upcase) })
    end
  end

  it "gives transform the normalized value" do
    expect_same("{a}", {"a" => "é"}, upcase)
  end

  it "gives transform the value as it is when normalize_values is false" do
    expect_same("{a}", {"a" => "é"}, upcase, false)
  end

  it "normalizes the transformed value" do
    expect_same("{a}", {"a" => "x"},
      transform: lambda { |_name, _value| "é" })
  end

  it "doesn't normalize the transformed value when normalize_values is false" do
    expect_same("{a}", {"a" => "x"},
      {transform: lambda { |_name, _value| "é" }}, false)
  end

  [42, nil, :sym, ["a", ["b", "c"]]].each do |result|
    it "joins a transform result of #{result.inspect}" do
      expect_same("{a}{/a}", {"a" => "x"},
        transform: lambda { |_name, _value| result })
    end
  end

  it "validates with the normalized value" do
    expect_same("{a}", {"a" => "é"},
      validate: lambda { |_name, _value| true })
  end

  ["bad", ["x", "y"], {"k" => "v"}].each do |value|
    it "raises for a value of #{value.inspect} that doesn't validate" do
      expect_same("{a}", {"a" => value},
        validate: lambda { |_name, _value| false })
    end
  end

  it "validates before transforming, for each variable in order" do
    expect_same("{a,b}{+a}", {"a" => "x", "b" => "y"},
      validate: lambda { |_name, _value| true },
      transform: lambda { |_name, value| value.upcase })
  end

  it "stops at the first value that doesn't validate" do
    expect_same("{a}{b}", {"a" => "x", "b" => "y"},
      validate: lambda { |name, _value| name != "a" },
      transform: lambda { |_name, value| value.upcase })
  end

  it "skips the processor for an undefined variable" do
    expect_same("{a}{b}", {"b" => "y"},
      validate: lambda { |_name, _value| true },
      transform: lambda { |_name, value| value.upcase })
  end

  it "raises for a prefix on a list before validating" do
    expect_same("{a:1}", {"a" => ["x"]},
      validate: lambda { |_name, _value| true })
  end

  it "encodes as usual with a processor that does neither" do
    expect_same("{a}", {"a" => "x y"}, {})
  end
end

context "Template::Machine::Variable with a prefix" do
  subject {
    Addressable::Template::Machine::Variable.new(
      op: Addressable::Template::Machine::OpPlain, name: "x", prefix: 3
    )
  }

  def expand(value)
    subject.expand_with(Addressable::Template::Values.new({"x" => value}, true))
  end

  it "truncates a string" do
    expect(expand("abcdef").value).to eq("abc")
  end

  it "raises InvalidTemplateValueError for a list" do
    expect { expand(["a", "b"]) }.to raise_error(
      Addressable::Template::InvalidTemplateValueError,
      "The prefix modifier :3 can't be applied to the list or associative " \
      "array \"x\"."
    )
  end

  it "raises InvalidTemplateValueError for an associative array" do
    expect { expand("a" => "b") }.to raise_error(
      Addressable::Template::InvalidTemplateValueError,
      "The prefix modifier :3 can't be applied to the list or associative " \
      "array \"x\"."
    )
  end
end

context "valid Template::Machine::Variable(explode: true)" do
  let(:op) { Addressable::Template::Machine::OpPlain }
  let(:name) { "foo" }
  subject {
    Addressable::Template::Machine::Variable.new(op: op, name: name, explode: true)
  }

  def expand(value)
    subject.expand_with(Addressable::Template::Values.new({name => value}, true))
  end

  it "does percent encoding for strings with reserved characters" do
    expect(expand("hello world!")).to contain_exactly(name, "hello%20world%21", nil)
  end

  it "can do a combination of normalize and join" do
    expect(expand(["a", "b", "hello world!"])).to contain_exactly(name, ["a","b","hello%20world%21"], nil)
    expect(expand({"foo" => "bar", "baz" => "qux"})).to contain_exactly(name, ["foo=bar","baz=qux"], true)
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
