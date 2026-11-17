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
require "timeout"
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

context "Template::Values#expand(variable) with explode: false" do
  let(:name) { "foo" }

  let(:op) { Addressable::Template::Machine::OpPlain }
  subject {
    Addressable::Template::Machine::Variable.new(op: op, name: name)
  }

  def expand(value)
    Addressable::Template::Values.new({name => value}, true).expand(subject)
  end

  context '#expand(variable)' do
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

  [
    ["{;a}", {"a" => ["x"]}, ""],
    ["{;a}", {"a" => {"k" => "v"}}, ""],
    ["{;a}", {"a" => "x"}, ""],
    ["{;a}", {"a" => ["x"]}, ["k=", "l=v"]],
    ["{;a*}", {"a" => {"k" => "v"}}, ["k=", "l=v"]],
    ["{;a}", {"a" => ["x"]}, ["", "y"]],
    ["{?a}", {"a" => ["x"]}, ""],
    ["{&a}", {"a" => ["x"]}, ["k=", "l=v"]]
  ].each do |pattern, mapping, result|
    it "joins a transform result of #{result.inspect} for #{mapping.inspect} in #{pattern}" do
      expect_same(pattern, mapping, transform: lambda { |_name, _value| result })
    end
  end

  it "joins a nil transform result in {;a} when normalize_values is false" do
    expect_same("{;a}", {"a" => "x"},
      {transform: lambda { |_name, _value| nil }}, false)
    expect_same("{;a}", {"a" => ["x"]},
      {transform: lambda { |_name, _value| nil }}, false)
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

describe Addressable::Template, "with the :machine engine, pct-encoded triplets" do
  def outcome(engine, pattern, mapping)
    Addressable::Template.new(pattern, engine: engine).expand(mapping).to_str
  rescue StandardError => error
    [error.class, error.message]
  end

  def expect_same(pattern, mapping)
    expect(outcome(:machine, pattern, mapping)).
      to eq(outcome(:regexp, pattern, mapping))
  end

  values = [
    "%41", "%e9", "a%2Fb", "%", "%4", "%zz", "100%", "%%41", "%41%",
    "caf%C3%A9", "%25", "% 41", "%4%41"
  ]
  ["", "+", "#", "/", ";", "?"].each do |operator|
    values.each do |value|
      it "expands {#{operator}x} with #{value.inspect}" do
        expect_same("{#{operator}x}", "x" => value)
      end
    end

    it "expands lists and hashes in {#{operator}x} and {#{operator}x*}" do
      list = ["%41", "%", "a%2Fb"]
      hash = {"%41" => "%42", "%" => "%zz"}
      expect_same("{#{operator}x}", "x" => list)
      expect_same("{#{operator}x*}", "x" => list)
      expect_same("{#{operator}x}", "x" => hash)
      expect_same("{#{operator}x*}", "x" => hash)
    end
  end

  ["", "+", "#"].each do |operator|
    [1, 2, 3, 4].each do |length|
      ["%41bc", "a%41", "%4", "%%41", "%E9%41x", "caf%C3%A9"].each do |value|
        it "takes {#{operator}x:#{length}} of #{value.inspect}" do
          expect_same("{#{operator}x:#{length}}", "x" => value)
        end
      end
    end

    it "takes {#{operator}x:2} of a value that isn't valid UTF-8" do
      expect_same("{#{operator}x:2}", "x" => "%41\xFF%42".b)
      expect_same("{#{operator}x:2}", "x" => "\xFF%41%42".b)
      expect_same("{#{operator}x:2}", "x" => "%4\xFF".b)
    end
  end

  it "keeps the triplets of a long value with many of them" do
    value = "%41%" * 10_000
    expect_same("{+x}", "x" => value)
    expect_same("{#x:9999}", "x" => value)
  end
end

describe Addressable::Template, "with the :machine engine, empty values" do
  def outcome(engine, pattern, mapping)
    Addressable::Template.new(pattern, engine: engine).expand(mapping).to_str
  end

  [
    "", ["", nil], [""], ["", ""], ["", "x"], ["x", ""], {"k" => ""},
    {"k" => "", "l" => "v"}, {"k" => "v", "l" => ""}, {"" => ""}, {"" => "v"}
  ].each do |value|
    ["", "+", "#", "/", ".", ";", "?", "&"].each do |operator|
      ["", "*"].each do |modifier|
        pattern = "{#{operator}a#{modifier},b}"
        it "expands #{pattern} with #{value.inspect}" do
          mapping = {"a" => value, "b" => "x"}
          expect(outcome(:machine, pattern, mapping)).
            to eq(outcome(:regexp, pattern, mapping))
        end
      end
    end
  end
end

describe Addressable::Template, "with the :machine engine, #partial_expand" do
  # The new pattern and its encoding, or the error's class and message.
  def outcome(engine, pattern, *args, &block)
    template = Addressable::Template.new(pattern, engine: engine)
    result = template.partial_expand(*args, &block)
    [result.pattern, result.pattern.encoding]
  rescue StandardError => error
    [error.class, error.message]
  end

  def expect_same(pattern, *args, &block)
    expect(outcome(:machine, pattern, *args, &block)).
      to eq(outcome(:regexp, pattern, *args, &block))
  end

  kinds = [:missing, nil, "", "x y", ["a", "b"], {"k" => "v"}, [], [nil]]
  ["", "+", "#", "/", ".", ";", "?", "&"].each do |operator|
    [["a", "b", "c"], ["a*", "b", "c:2"], ["a", "a", "b"]].each do |varspecs|
      pattern = "x{#{operator}#{varspecs.join(',')}}y"
      it "partially expands #{pattern} with every mix of values" do
        names = varspecs.map { |varspec| varspec[/\A\w+/] }.uniq
        mismatches = kinds.product(*[kinds] * (names.size - 1)).
          map do |combination|
            mapping = {}
            names.zip(combination).each do |name, kind|
              mapping[name] = kind unless kind == :missing
            end
            machine = outcome(:machine, pattern, mapping)
            regexp = outcome(:regexp, pattern, mapping)
            [mapping, machine, regexp] unless machine == regexp
          end.compact
        expect(mismatches).to eq([])
      end
    end
  end

  it "keeps literals as they are written" do
    expect_same("é/{a}/{b}#x", "a" => "v")
    expect_same("a b\xE9/{a}{b}".dup.force_encoding(Encoding::ISO_8859_1),
      "a" => "v")
    expect_same("%zz{a}", "a" => "v")
  end

  it "expands every expression whose variables are all given" do
    expect_same("{a}/{+b}{#c}{?d,e}", "a" => "1", "b" => "/", "c" => "#",
      "d" => ["x"], "e" => {"k" => ""})
  end

  it "leaves a template with no variables given as it is" do
    expect_same("{a}/{+b}{#c}{?d,e}", {})
  end

  it "keeps the engine" do
    template = Addressable::Template.new("{a}{b}", engine: :machine)
    expect(template.partial_expand("a" => "x").engine).to eq(:machine)
  end

  # Not always the whole expansion: a query moves its first defined
  # variable to the front, as Template does.
  it "expands the rest of a partial expansion as Template does" do
    pattern = "{a}/{?b,c,d}{#e,f}"
    whole = {"a" => "1", "b" => "2", "c" => nil, "d" => ["4"], "f" => "6"}
    ["a", "b", "c", "d", "e", "f"].each do |name|
      first = whole.select { |key, _| key == name }
      rest = whole.reject { |key, _| key == name }
      results = [:machine, :regexp].map do |engine|
        Addressable::Template.new(pattern, engine: engine).
          partial_expand(first).expand(rest).to_str
      end
      expect(results.first).to eq(results.last)
    end
  end

  it "looks variables up with a block" do
    values = {"a" => "1", "c" => nil, "d" => "4"}
    expect_same("{a}{b}{?c,d}") { |name| values.fetch(name) }
  end

  it "takes a KeyError from a lambda as a missing variable" do
    values = {"a" => "x"}
    expect_same("{a}{?b,a}", lambda { |name| values.fetch(name) })
  end

  it "asks key? of a mapping that has it" do
    lookup = Object.new
    def lookup.key?(name); name != "b"; end
    def lookup.[](name); name == "c" ? nil : name; end
    expect_same("{a,b,c}{?b,c,a}", lookup)
  end

  it "raises for both a mapping and a block, or neither" do
    expect_same("{a}", {}) { |name| name }
    expect_same("{a}")
  end

  it "raises for a mapping it can't read" do
    expect_same("{a}", "a")
    expect_same("{a}", nil)
  end

  it "raises for a value of the wrong type in a given variable" do
    expect_same("{?a,b,c}", "a" => "1", "c" => Object.new)
  end

  it "raises for a pattern that isn't valid" do
    expect_same("{a}{", "a" => "x")
    expect_same("{!a}", "a" => "x")
  end

  it "uses a processor for the variables it expands" do
    calls = []
    processor = Object.new
    processor.define_singleton_method(:validate) do |name, value|
      calls << [name, value]
      true
    end
    processor.define_singleton_method(:transform) { |_name, value| value.upcase }
    expect_same("{a,b}{?c,a}", {"a" => "x", "c" => "y"}, processor)
    expect(calls.uniq).to eq([["a", "x"], ["c", "y"]])
  end

  it "doesn't normalize values when normalize_values is false" do
    expect_same("{a}{b}", {"a" => "é"}, nil, false)
    expect_same("{a}{b}", {"a" => "é"}, nil, true)
  end

  it "partially expands a long template in linear time" do
    pattern = "{a}{b}" * 20_000
    template = Addressable::Template.new(pattern, engine: :machine)
    expect { Timeout.timeout(10) { template.partial_expand("a" => "x") } }.
      not_to raise_error
    expect_same(pattern, "a" => "x")
  end
end

describe Addressable::Template::Values, "#key? and #defined_value?" do
  def values(mapping)
    Addressable::Template::Values.new(mapping, true)
  end

  it "says whether a variable is given, and whether it's defined" do
    lookup = values("a" => "x", "b" => nil, "c" => [nil], "d" => Object.new)
    expect(["a", "b", "c", "d", "e"].map { |name| lookup.key?(name) }).
      to eq([true, true, true, true, false])
    expect(["a", "b", "c", "d", "e"].map { |name| lookup.defined_value?(name) }).
      to eq([true, false, false, true, false])
  end

  it "doesn't type-check or prepare a value to say it's defined" do
    lookup = values("a" => Object.new)
    expect(Addressable::Template::Values).not_to receive(:normalize_value)
    expect(lookup.defined_value?("a")).to be true
  end
end

describe Addressable::Template::Machine::Variable, "#varspec" do
  it "writes the varspec as the pattern had it" do
    expect(Addressable::Template::Lexer.new.parse_nodes("{a,b*,c:12,d.e,%41}").
      first.variables.map(&:varspec)).to eq(["a", "b*", "c:12", "d.e", "%41"])
  end
end

describe Addressable::Template::Machine::Literal do
  def literal(text)
    described_class.new(text)
  end

  it "keeps its text as the pattern wrote it" do
    expect(literal("é/%C3%A9").text).to eq("é/%C3%A9")
  end

  it "expands to ASCII text as it is" do
    text = "a/b%41?"
    expect(literal(text).expand(nil)).to equal(text)
  end

  it "expands with non-ASCII characters pct-encoded" do
    expect(literal("é/%C3%A9 x").expand(nil)).to eq("%C3%A9/%C3%A9 x")
  end

  it "expands the bytes of text in another encoding as they are" do
    text = "a\xE9".dup.force_encoding(Encoding::ISO_8859_1)
    expect(literal(text).expand(nil)).to eq("a%E9")
  end

  it "partially expands to its text as written" do
    text = "é/"
    expect(literal(text).partial_expand(nil)).to equal(text)
  end

  it "has no variables" do
    expect(literal("a").variables).to eq([])
  end
end

describe Addressable::Template, "with the :machine engine, literals" do
  def outcome(engine, pattern, mapping)
    uri = Addressable::Template.new(pattern, engine: engine).expand(mapping)
    [uri.to_str, uri.to_str.encoding]
  rescue StandardError => error
    [error.class, error.message]
  end

  def expect_same(pattern, mapping = {"a" => "v"})
    expect(outcome(:machine, pattern, mapping)).
      to eq(outcome(:regexp, pattern, mapping))
  end

  [
    "é/{a}", "{a}é", "xéy{a}zé", "\u{1F642}{a}",
    "caf%C3%A9/{a}", "café%C3%A9/{a}", "a b/{a}", "%/{a}", "{a}%zz",
    "http://é.example/{a}?q=é"
  ].each do |pattern|
    it "expands #{pattern.inspect}" do
      expect_same(pattern)
    end
  end

  it "keeps the bytes of a literal in another encoding" do
    expect_same("a b\xE9/{a}".dup.force_encoding(Encoding::ISO_8859_1))
    expect_same("\x82\xA0/{a}".dup.force_encoding(Encoding::Shift_JIS))
    expect_same("\xE9/{a}".b)
    expect_same("a/{a}".dup.force_encoding(Encoding::US_ASCII))
  end

  it "raises for a UTF-8 literal that isn't valid" do
    expect_same("\xE9/{a}".dup.force_encoding(Encoding::UTF_8))
  end

  [
    ['x#y#{a}', {"a" => "v"}],
    ['{#a}#b', {"a" => "v"}],
    ['{#a}{#b}', {"a" => "v", "b" => "w"}],
    ['{#a}', {"a" => ["#", "#x"]}],
    ['{+a}', {"a" => "#x#y"}],
    ['{+a}{#b}', {"a" => "#x", "b" => "#"}],
    ['#{a}', {"a" => "#"}],
    ['{a}#', {"a" => "#"}],
    ['{#a}', {}],
    ["é#é" + '#{a}', {"a" => "v"}]
  ].each do |pattern, mapping|
    it "encodes a later number sign in #{pattern.inspect} with #{mapping.inspect}" do
      expect_same(pattern, mapping)
    end
  end

  it "encodes a long non-ASCII literal in linear time" do
    pattern = "é" * 100_000 + "{a}"
    expect_same(pattern)
    template = Addressable::Template.new(pattern, engine: :machine)
    expect { Timeout.timeout(10) { template.expand("a" => "v") } }.
      not_to raise_error
  end

  it "encodes many number signs in linear time" do
    expect_same('#{a}' + "#" * 100_000, "a" => "#" * 100_000)
  end

  it "matches a non-ASCII literal written as it is" do
    template = Addressable::Template.new("é/{a}", engine: :machine)
    expect(template.match("é/v").mapping).to eq("a" => "v")
  end
end

describe Addressable::Template::Values, ".encode_later_number_signs" do
  def encode(uri)
    Addressable::Template::Values.encode_later_number_signs(uri)
  end

  it "leaves a URI with no number sign" do
    expect(encode("a/b")).to eq("a/b")
  end

  it "keeps the first number sign and encodes the rest" do
    expect(encode("a#b#c#")).to eq("a#b%23c%23")
    expect(encode("##")).to eq("#%23")
  end

  it "returns a URI with one number sign as it is" do
    uri = "a#b"
    expect(encode(uri)).to equal(uri)
    expect(encode("#")).to eq("#")
  end
end

describe Addressable::Template::Values, ".prefix" do
  def prefix(*args)
    Addressable::Template::Values.prefix(*args)
  end

  it "takes characters when reserved characters aren't allowed" do
    expect(prefix("%41bc", 2, false)).to eq("%4")
  end

  it "counts a pct-encoded triplet as one character otherwise" do
    expect(prefix("%41bc", 2, true)).to eq("%41b")
    expect(prefix("%4bc", 2, true)).to eq("%4bc")
    expect(prefix("%4zc", 2, true)).to eq("%4")
  end

  it "reads a value that isn't valid UTF-8 one character at a time" do
    expect(prefix("%41\xFF%42".b.force_encoding(Encoding::UTF_8), 3, true).b).
      to eq("%41\xFF%42".b)
    expect(prefix("\xFF%4".b.force_encoding(Encoding::UTF_8), 2, true).b).
      to eq("\xFF%".b)
  end
end

describe Addressable::Template::Machine::Variable do
  def variable(op)
    Addressable::Template::Machine::Variable.new(op: op, name: "x")
  end

  it "allows reserved characters as its operator does" do
    expect(variable(Addressable::Template::Machine::OpReserved).
      allows_reserved?).to be true
    expect(variable(Addressable::Template::Machine::OpFragment).
      allows_reserved?).to be true
    expect(variable(Addressable::Template::Machine::OpPlain).
      allows_reserved?).to be false
  end

  it "tags an expanded value with its operator's tagged value" do
    tagged = variable(Addressable::Template::Machine::OpForm).
      tag("v", nil, false)
    expect(tagged).to be_a(Addressable::Template::Machine::NamedTaggedValue)
    expect(tagged.to_a).to eq(["x", "v", nil, false])
  end
end

context "Template::Values#expand(variable) with a prefix" do
  subject {
    Addressable::Template::Machine::Variable.new(
      op: Addressable::Template::Machine::OpPlain, name: "x", prefix: 3
    )
  }

  def expand(value)
    Addressable::Template::Values.new({"x" => value}, true).expand(subject)
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

context "Template::Values#expand(variable) with explode: true" do
  let(:op) { Addressable::Template::Machine::OpPlain }
  let(:name) { "foo" }
  subject {
    Addressable::Template::Machine::Variable.new(op: op, name: name, explode: true)
  }

  def expand(value)
    Addressable::Template::Values.new({name => value}, true).expand(subject)
  end

  it "does percent encoding for strings with reserved characters" do
    expect(expand("hello world!").to_a).to eq([name, "hello%20world%21", nil, false])
  end

  it "can do a combination of normalize and join" do
    expect(expand(["a", "b", "hello world!"]).to_a).to eq([name, ["a","b","hello%20world%21"], nil, true])
    expect(expand({"foo" => "bar", "baz" => "qux"}).to_a).to eq([name, ["foo=bar","baz=qux"], true, true])
  end
end

describe Addressable::Template, "with the :machine engine, #match" do
  # The match's mapping, URI and URI class, nil, or the error.
  def outcome(engine, pattern, uri)
    match = Addressable::Template.new(pattern, engine: engine).match(uri)
    match && [match.mapping, match.uri, match.uri.class]
  rescue StandardError => error
    [error.class, error.message]
  end

  def expect_same(pattern, uri)
    expect(outcome(:machine, pattern, uri)).
      to eq(outcome(:regexp, pattern, uri)), "for #{uri.inspect}"
  end

  {
    "{/foo*}" => [
      "/true", "/42", "/hello%20world%21", "/", "", "/a/b/hello%20world%21",
      "/foo=bar/baz=qux"
    ],
    "http://example.com/{a}/{b}" => [
      "http://example.com/x/y", "http://example.com/x", "http://example.org/x/y"
    ],
    "{+base}{/path*}{?q*}{#f}" => [
      "http://x.org/a/b?k=v&j=w#f", "/a?k", "", "#a#b", "?a=1&a=2"
    ],
    "{a}" => ["x y", "%zz", "%", "é", "€", "\u{1F642}", "a%2Cb"],
    # Each operator's values and exploded members, a + or # variable before
    # the last, and a joiner left before a later variable.
    "{+a,b}{#c*}" => ["x,y#p,q", "x/y,z#p", "#p,,q", ""],
    "{+a*}/{d}" => ["x,y/z/w", "/w"],
    "{;a,b}{;c*}" => [";a=1;b;c=2;d", ";a;c", ";=;"],
    "{?a,b}{&c*}" => ["?a=1&b=2&c=3&d=4", "?a=&b"],
    "{a*,b}" => ["x,y,z", "x,,y"],
    "{/a*,b}" => ["/x/y/z", "/x//"],
    "{.a*}{.b}" => [".x.y.z"],
    # A value that the next expression can take over at any position, and
    # one that ends at a literal inside its run.
    "{a}{b}" => ["xyz", "x%41y"],
    "{+a}{b}" => ["p/qr", "p/q/r", "é/q"],
    "{+a}/{b}" => ["x/y/z", "x%2Fy/z", "/"],
    "{a}.json" => ["x.json", "x.y.json", "x.jsonx"]
  }.each do |pattern, uris|
    it "matches like the :regexp engine for #{pattern}" do
      uris.each { |uri| expect_same(pattern, uri) }
    end
  end

  # A non-ASCII literal matches as it is or pct-encoded in either case, and
  # an ASCII one only as written.
  {
    "é/{a}" => ["é/v", "%C3%A9/v", "%c3%a9/v", "%C3%a9/v", "e/v"],
    "caf%C3%A9/{a}" => ["café/v", "caf%c3%a9/v", "caf%C3%A9/v"],
    "%41/{a}" => ["%41/v", "%61/v", "A/v", "%41/"],
    "%E9/{a}" => ["%E9/v", "%e9/v", "é/v"],
    "\u{1F642}{a}" => ["\u{1F642}v", "%F0%9F%99%82v", "%f0%9f%99%82"],
    "é" => ["é", "%C3%A9", "%c3%a9", "e"],
    "a" => ["a", "A", "%61"]
  }.each do |pattern, uris|
    it "matches literals in #{pattern.inspect} like the :regexp engine" do
      uris.each { |uri| expect_same(pattern, uri) }
    end
  end

  # Template's regexp takes the encoding of the literals' non-ASCII
  # characters, so it raises Encoding::CompatibilityError for a non-ASCII
  # URI when that isn't UTF-8, and for characters in two encodings.
  it "matches literals from a pattern in another encoding like the :regexp engine" do
    [
      "a b\xE9/{a}".dup.force_encoding(Encoding::ISO_8859_1),
      "\x82\xA0/{a}".dup.force_encoding(Encoding::Shift_JIS),
      "\xE9/{a}".b,
      "a/{a}".dup.force_encoding(Encoding::US_ASCII),
      "%C3%A9/{a}".dup.force_encoding(Encoding::ISO_8859_1),
      "\xE9%C3%A9/{a}".dup.force_encoding(Encoding::ISO_8859_1),
      "\xE9/{a}/%C3%A9".dup.force_encoding(Encoding::ISO_8859_1)
    ].each do |pattern|
      ["a b%E9/v", "%82%A0/v", "%E9/v", "a/v", "é/v"].each do |uri|
        expect_same(pattern, uri)
      end
    end
  end

  it "freezes a pattern with literals in two encodings like the :regexp engine" do
    pattern = "\xE9%C3%A9/{a}".dup.force_encoding(Encoding::ISO_8859_1)
    outcomes = [:regexp, :machine].map do |engine|
      begin
        Addressable::Template.new(pattern, engine: engine).freeze
        nil
      rescue StandardError => error
        [error.class, error.message]
      end
    end
    expect(outcomes.last).to eq(outcomes.first)
  end

  # Once a fragment may have started, a later "#" matches as it is or as
  # "%23", in a literal or a fragment expression's leader.
  {
    'x#y#{a}' => ["x#y#v", "x#y%23v", "x%23y#v"],
    '{#a}#b' => ["#x#b", "#x%23b", "#x"],
    '{+a}{#b}' => ["#x%23y", "x#y", "x%23y"],
    '{+a}#{b}' => ["x%23y", "x#y"],
    '#{a}{#b}' => ["#x%23y", "#x#y"],
    '{#a}{#b}' => ["#x#y", "#x%23y"]
  }.each do |pattern, uris|
    it "matches number signs in #{pattern} like the :regexp engine" do
      uris.each { |uri| expect_same(pattern, uri) }
    end
  end

  # A label's value takes dots where nothing after it could continue it.
  {
    "{.a}" => [".x.y", ".x", "."],
    "/{.a}/" => ["/.x.y/", "/.x/"],
    "{a}{.b}" => ["x.y.z"],
    "x{.a}" => ["x.y.z"],
    "/{.a}{/b}" => ["/.x.y/z"],
    "/{.a}{?b}" => ["/.x.y?b=1"],
    "/{.a}{#b}" => ["/.x.y#z"],
    "{#x}/{.a}{#b}" => ["#q/.x.y#z", "#q/.x.y%23z"],
    "/{.a}#x" => ["/.x.y#x"],
    "{#q}/{.a}#x" => ["#q/.x.y#x", "#q/.x.y%23x"],
    "/{.a*}/" => ["/.x.y/"],
    "/{.a:2}/" => ["/.x.y/"],
    "/{.a,b}/" => ["/.x.y/"],
    "/{.a}x" => ["/.x.yx"]
  }.each do |pattern, uris|
    it "matches labels in #{pattern} like the :regexp engine" do
      uris.each { |uri| expect_same(pattern, uri) }
    end
  end

  it "matches an Addressable::URI like the :regexp engine" do
    expect_same("http://example.com/{a}",
      Addressable::URI.parse("http://example.com/x"))
    expect_same("http://example.com/{a}",
      Addressable::URI.parse("http://example.com/x/y"))
  end

  it "matches text that isn't a valid URI like the :regexp engine" do
    expect_same("http://{a}/", "http://[/")
    expect_same("{a}", "\xE9".dup.force_encoding(Encoding::UTF_8))
    expect_same("{a}", "\xC3\xA9".b)
    expect_same("{a}", "\xE9".b)
  end

  it "raises for nil like the :regexp engine" do
    expect_same("{a}", nil)
  end

  it "raises for a template that isn't valid like the :regexp engine" do
    expect_same("{a", "x")
    expect_same("{a}{!b}", "x")
  end

  it "doesn't build a regexp" do
    template = Addressable::Template.new("{/a*}{?b}", engine: :machine)
    expect(Regexp).not_to receive(:new)
    expect(template.match("/x/y?b=1").mapping).to eq(
      "a" => ["x", "y"], "b" => "1"
    )
  end

  it "matches a frozen template" do
    template = Addressable::Template.new("{/a*}", engine: :machine).freeze
    expect(template.match("/x/y").mapping).to eq("a" => ["x", "y"])
  end

  # Runs tried from their end back (a greedy run's ends), runs that end at
  # a literal, and possessive runs each read the URI once.
  {
    "{;a,b}" => ";a=", "{;a,b}x" => ";a=", "{?a,b}" => "?a=",
    "{+a}/{b}" => "", "{+a,b,c}" => "", "{a}.json" => "", "{/a*}" => "/",
    "{.a}" => ".", "{a}{b}" => "", "{#a,b}" => "#"
  }.each do |pattern, prefix|
    it "matches #{pattern} in linear time" do
      template = Addressable::Template.new(pattern, engine: :machine)
      ["a", "é", "a/"].each do |unit|
        uri = prefix + unit * 50_000 + "!"
        expect { Timeout.timeout(5) { template.match(uri) } }.
          not_to raise_error
      end
    end
  end

  context "with a processor" do
    # A processor whose match gives patterns for some names, and records
    # each call.
    def processor(patterns, calls = [])
      processor = Object.new
      processor.define_singleton_method(:match) do |name|
        calls << name
        patterns[name]
      end
      processor
    end

    def outcome_with(engine, pattern, uri, processor)
      match = Addressable::Template.new(pattern, engine: engine).
        match(uri, processor)
      match && [match.mapping, match.uri]
    rescue StandardError => error
      [error.class]
    end

    def expect_same_with(pattern, uri, patterns)
      calls = {:regexp => [], :machine => []}
      outcomes = [:regexp, :machine].map do |engine|
        outcome_with(engine, pattern, uri, processor(patterns, calls[engine]))
      end
      expect(outcomes.last).to eq(outcomes.first), "for #{uri.inspect}"
      expect(calls[:machine]).to eq(calls[:regexp])
    end

    {
      ["{a}", {"a" => ".*"}] => ["xyz", "", "x/y"],
      ["{a}{b}", {"a" => ".*?"}] => ["xyz", "x"],
      ["{a}{b}", {"a" => ".*"}] => ["xyz"],
      ["{a}{b}", {"b" => "[0-9]+"}] => ["x12", "12", "x"],
      ["{/a,b,c}", {"b" => "[0-9]+"}] => ["/x/1/y", "/x1", "/1", "/x/y"],
      ["{+a}/{b}", {"a" => ".*"}] => ["x/y/z", "/"],
      ["/{a*}", {"a" => "[a-z,]*"}] => ["/x,y", "/"],
      ["{?q,lang}", {"q" => "[^&]*"}] => ["?q=a&lang=b", "?q=a"],
      ["{;a,b}", {"a" => "a=[0-9]+"}] => [";a=1;b=2", ";a=x"],
      ["{a}.{b}", {"a" => "\\w+(?=\\.)"}] => ["x.y", "x.y.z"],
      ["{a}{b}", {"b" => "(?<=x)y"}] => ["xy", "y"],
      ["{a}/{b}", {"a" => "café"}] => ["café/v", "caf%C3%A9/v"],
      ["{a}", {"a" => ""}] => ["", "x"]
    }.each do |(pattern, patterns), uris|
      it "matches #{pattern} with #{patterns.inspect} like the :regexp engine" do
        uris.each { |uri| expect_same_with(pattern, uri, patterns) }
      end
    end

    it "raises RegexpError for a pattern that isn't valid, like :regexp" do
      expect_same_with("{a}", "x", "a" => "*")
    end

    it "calls match once per varspec, in order, like :regexp" do
      expect_same_with("{a,b}/{a}{?c}", "x,y/z?c=1", {})
    end

    it "doesn't call match for text that isn't valid UTF-8, like :regexp" do
      invalid = "\xE9".dup.force_encoding(Encoding::UTF_8)
      expect_same_with("{a}", invalid, {})
      calls = []
      template = Addressable::Template.new("{a}", engine: :machine)
      expect(template.match(invalid, processor({}, calls))).to be_nil
      expect(calls).to eq([])
    end

    it "uses the cached matcher with a processor that only restores" do
      restorer = Class.new { def self.restore(_name, value) value end }
      expect_same_with("/files/{+path}{?q}", "/files/a%2Fb?q=c%20d", {})
      template = Addressable::Template.new("{/a}", engine: :machine)
      template.match("/x")
      expect(Addressable::Template::Matcher).not_to receive(:new)
      expect(template.match("/x", restorer).mapping).to eq("a" => "x")
    end
  end

  it "matches with variable names that start with a digit" do
    expect_same("{1a}/{2b*}", "x/y,z")
  end
end

describe Addressable::Template::Matching, ".literal_units" do
  {
    ["a.b", false] => [["a", nil], [".", nil], ["b", nil]],
    ["#a#b", false] => [["#", nil], ["a", nil], ["#", "%23"], ["b", nil]],
    ["#a", true] => [["#", "%23"], ["a", nil]],
    ["é", false] => [["é", "%C3%A9"]],
    ["%C3%A9", false] => [["é", "%C3%A9"]],
    ["%41", false] => [["%41", nil]],
    ["%E9", false] => [[nil, "%E9"]],
    ["", false] => []
  }.each do |(text, fragment), units|
    it "splits #{text.inspect}#{" after a fragment" if fragment}" do
      expect(described_class.literal_units(text, fragment)).to eq(units)
    end
  end
end

describe Addressable::Template::Matching, ".literal_source" do
  def source(text, fragment)
    described_class.literal_source(
      described_class.literal_units(text, fragment)
    )
  end

  {
    ["a.b", false] => "a\\.b",
    ["#a#b", false] => "\\#a(?:\\#|%23)b",
    ["#a#b", true] => "(?:\\#|%23)a(?:\\#|%23)b",
    ["é", false] => "(?:é|(?i:%C3%A9))",
    ["%C3%A9", false] => "(?:é|(?i:%C3%A9))",
    ["%41", false] => "%41",
    ["%E9", false] => "(?i:%E9)",
    ["", false] => ""
  }.each do |(text, fragment), expected|
    it "writes #{text.inspect}#{" after a fragment" if fragment}" do
      expect(source(text, fragment)).to eq(expected)
    end
  end

  it "keeps a literal's encoding" do
    latin1 = "\xE9".dup.force_encoding(Encoding::ISO_8859_1)
    expect(source(latin1, false)).to eq(
      "(?:#{latin1}|(?i:%E9))".dup.force_encoding(Encoding::ISO_8859_1)
    )
  end
end

describe Addressable::Template::Matching, ".capture_name" do
  dot_allowed = Addressable::Template.const_get(:GROUP_NAME_CAN_START_WITH_DOT)

  it "keeps a name that starts with a letter or _" do
    expect(described_class.capture_name("a.b")).to eq("a.b")
    expect(described_class.capture_name("_4")).to eq("_4")
  end

  it "names the group of a name that starts with a digit" do
    expect(described_class.capture_name("42")).to eq(
      dot_allowed ? ".42" : "__42__"
    )
  end

  it "names the group of a name that starts with a triplet" do
    expect(described_class.capture_name("%41")).to eq(
      dot_allowed ? "%41" : "__%41__"
    )
  end
end

describe Addressable::Template::ParsedTemplate, "#to_regexp" do
  # The machine's regexp or the :regexp engine's, with its source and that
  # source's encoding, or the error.
  def regexp(engine, pattern)
    template = Addressable::Template.new(pattern, engine: engine)
    regexp =
      if engine == :machine
        described_class.new(template).to_regexp
      else
        template.to_regexp
      end
    [regexp, regexp.source, regexp.source.encoding]
  rescue StandardError => error
    [error.class, error.message]
  end

  def expect_same_source(pattern)
    expect(regexp(:machine, pattern)).to eq(regexp(:regexp, pattern)),
      "for #{pattern.inspect}"
  end

  # Shapes the builder writes without rewriting a varspec or an
  # expression for what's around it.
  {
    "literals" => ["", "/a/b", "a.b?c", "é/{a}", "%C3%A9/{a}", "%E9/{a}",
                   "%41/{a}", "\u{1F642}{a}"],
    "every operator" => ["{a}", "{+a}", "{#a}", "{/a}", "{.a}", "{;a}",
                         "{?a}", "{&a}"],
    "exploded values" => ["{a*}", "{+a*}", "{#a*}", "{/a*}", "{.a*}",
                          "{;a*}", "{?a*}", "{&a*}"],
    "prefixes and names" => ["{a:3}", "{42}", "{%41}", "{a.b}", "{_4}"],
    "lists" => ["{a*,b}", "{/a*,b}", "{.a*,b}", "{+a,b},", "{#a,b,c},x",
                "{+a,b*}", "{?a,b}", "{&a,b,c}", "{?a,b*}", "{&a,b,a}"],
    "fragments" => ['#{#a}', '{+a}{#b}', '#{a}#{b}', '{#a}#', 'x#y{#a}'],
    "labels" => ["{.a}", "/{.a}/", "x{.a}y", "{.a}{/b}", '{.a}#{b}',
                 "{.a}?{b}", "{.a:3}"],
    "neighbours that don't take each other's values" => [
      "{a}{?b}", "{+a}{/b}", "{/a}{;b}", "{?a}{&b}"
    ],
    # A + # or ; varspec after an exploded one, an exploded default, / or
    # . varspec with another exploded one after it, and a ? or & varspec
    # right after an exploded one.
    "varspecs after an exploded one" => [
      "{+a*,b}", "{+a*,b*}", "{+a*,b,c}", "{#a,b*,c}", "{+a*,b,b}",
      "{#a*,b*,c}", "{;a*,b}", "{;a*,b*}", "{;a*,b,c*}",
      "{a*,b*}", "{/a*,b*}", "{.a*,b*}", "{/a*,b*,c}", "{a*,b*,c*}",
      "{?a*,b}", "{?a*,b*}", "{&a*,b}", "{?a,b*,c}", "{&a*,b*,c}"
    ],
    # A ; varspec after the first, and an unexploded default, / or .
    # varspec before the last.
    "; varspecs and varspecs before the last" => [
      "{;a,b}", "{;a,b,c}", "{;a,b*}", "{;a:3,b}", "{;a,b*,c}",
      "{a,b}", "{/a,b}", "{.a,b}", "{a,b,c}", "{a,b*}", "{/a,b,c*}",
      "{a*,b,c*}", "x{.a,b}y", "{a:2,a}"
    ]
  }.each do |shape, patterns|
    it "writes the same source as the :regexp engine for #{shape}" do
      patterns.each { |pattern| expect_same_source(pattern) }
    end
  end

  it "writes literals from a pattern in another encoding like :regexp" do
    [
      "a b\xE9/{a}".dup.force_encoding(Encoding::ISO_8859_1),
      "\x82\xA0/{a}".dup.force_encoding(Encoding::Shift_JIS),
      "\xE9/{a}".b,
      "a/{a}".dup.force_encoding(Encoding::US_ASCII),
      "\xE9%C3%A9/{a}".dup.force_encoding(Encoding::ISO_8859_1),
      "\xE9/{a}/%C3%A9".dup.force_encoding(Encoding::ISO_8859_1)
    ].each { |pattern| expect_same_source(pattern) }
  end

  it "raises for a template that isn't valid like :regexp" do
    ["{a", "a}", "{!a}", "{a b}"].each { |pattern| expect_same_source(pattern) }
  end
end

describe Addressable::Template, "with the :machine engine, #named_captures" do
  # The named captures, or the error.
  def named_captures(engine, pattern)
    Addressable::Template.new(pattern, engine: engine).named_captures
  rescue StandardError => error
    [error.class, error.message]
  end

  # Every operator, with and without prefixes and explode, names used more
  # than once, and the shapes Template's builder writes differently: + and
  # # lists with nothing after them, values a later expression takes over,
  # and processor-free runs of exploded variables.
  [
    "", "/a/b", "{a}", "{a,b}", "{a,b,a}", "{/a,b*}{?c,a}",
    "{+a}", "{+a,b}", "{+a,b}/", "{+a,b},", "{#a,b*}", "{+a}{b}",
    "{.a}", "{.a,b}.json", "{/a*,b}", "{a*,b*}",
    "{;a,b}", "{;a*,b}", "{?a,b}", "{?a*,b}", "{&a,b}",
    "{a:3}/{a}", "{a}{a}{a}",
    "{42}", "{1a}/{2b*}", "/{42}/{_42}", "{a.b}", "{a%20b}",
    "{x.y}/{%41}{?q}", "{%41}{%41}",
    'http://example.com/{a}/{b}{?c*}#{d}'
  ].each do |pattern|
    it "gives the same named captures as :regexp for #{pattern.inspect}" do
      expect(named_captures(:machine, pattern)).to eq(
        named_captures(:regexp, pattern)
      )
    end
  end

  it "numbers each varspec, in template order" do
    template = Addressable::Template.new("{/a,b*}{?c,a}", engine: :machine)
    expect(template.named_captures).to eq(
      "a" => [1, 4], "b" => [2], "c" => [3]
    )
  end

  it "raises for a template that isn't valid like the :regexp engine" do
    ["{a", "a}", "{a}{!b}", "{a b}", "{a:0}", "{{a}}"].each do |pattern|
      expect(named_captures(:machine, pattern)).to eq(
        named_captures(:regexp, pattern)
      ), "for #{pattern.inspect}"
    end
  end

  it "doesn't build a regexp" do
    template = Addressable::Template.new("{/a*}{?b}", engine: :machine)
    expect(Regexp).not_to receive(:new)
    expect(template.named_captures).to eq("a" => [1], "b" => [2])
  end

  it "gives the named captures of a frozen template" do
    template = Addressable::Template.new("{a}{b}", engine: :machine).freeze
    expect(template.named_captures).to eq("a" => [1], "b" => [2])
  end
end
