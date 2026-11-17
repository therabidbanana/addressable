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
