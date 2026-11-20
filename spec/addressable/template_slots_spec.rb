# frozen_string_literal: true

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

require "addressable/template"

describe Addressable::Template::Machine::Slots do
  # A processor that gives the named variables a pattern, and notes the
  # names it's asked for.
  class SlotsSpecProcessor
    attr_reader :asked

    def initialize(patterns)
      @patterns = patterns
      @asked = []
    end

    def match(name)
      @asked << name
      @patterns[name]
    end
  end

  def parse(pattern)
    Addressable::Template::Parser.new.parse_nodes(pattern)
  end

  # Each slot as its varspec, then how it matches: :own for a value of its
  # own, :nothing for a variable that never takes anything, and for a name
  # written again, [:same, group] or [:extends, group] with the earlier
  # varspec's group.
  def roles(pattern, processor = nil)
    nodes = parse(pattern)
    slots = described_class.new(nodes, processor)
    nodes.flat_map { |node| slots.of(node) }.map do |slot|
      role =
        if slot.absorbed
          :nothing
        elsif slot.repeated.nil?
          :own
        elsif slot.repeated.extends?
          [:extends, slot.repeated.first_group]
        else
          [:same, slot.repeated.first_group]
        end
      [slot.variable.pattern_text, role]
    end
  end

  {
    "" => [],
    "a/b" => [],
    "{a}" => [["a", :own]],
    "{a}{b}" => [["a", :own], ["b", :own]],
    "x{?a,b}y{/c}" => [["a", :own], ["b", :own], ["c", :own]],
    # An exploded variable right after another in its expression.
    "{;a*,b*}" => [["a*", :own], ["b*", :nothing]],
    "{/a*,b*,c*}" => [["a*", :own], ["b*", :nothing], ["c*", :nothing]],
    "{/a*,b,c*}" => [["a*", :own], ["b", :own], ["c*", :own]],
    # Not across expressions.
    "{/a*}{/b*}" => [["a*", :own], ["b*", :own]],
    # A name written again, where the earlier value's place is decided.
    "{a}/{a}" => [["a", :own], ["a", [:same, 0]]],
    "/{lang}/docs{?lang}" => [["lang", :own], ["lang", [:same, 0]]],
    "{.who,who}" => [["who", :own], ["who", [:same, 0]]],
    "{a}/{a}/{a}" => [["a", :own], ["a", [:same, 0]], ["a", [:same, 0]]],
    "{a}/{b}/{b}" => [["a", :own], ["b", :own], ["b", [:same, 1]]],
    "{/var:1,var}" => [["var:1", :own], ["var", [:extends, 0]]],
    "{/var,var:1}" => [["var", :own], ["var:1", [:same, 0]]],
    # Where it isn't decided, the name matches as if written once.
    "{a}{a}" => [["a", :own], ["a", :own]],
    "{a}{b}{a}" => [["a", :own], ["b", :own], ["a", :own]],
    "{a}/{b}/{a}" => [["a", :own], ["b", :own], ["a", :own]],
    "{b}{a}/{a}" => [["b", :own], ["a", :own], ["a", :own]],
    "{+a}/{+a}" => [["a", :own], ["a", :own]],
    "{/a}{/a*}" => [["a", :own], ["a*", :own]],
    "{/a*}{/a}" => [["a*", :own], ["a", :own]],
    "{/a:1,a:2}" => [["a:1", :own], ["a:2", :own]]
  }.each do |pattern, expected|
    it "gives #{pattern.inspect} the slots #{expected.inspect}" do
      expect(roles(pattern)).to eq(expected)
    end
  end

  it "numbers the groups in order across the template" do
    nodes = parse("{a,b}/{c}")
    slots = described_class.new(nodes)
    groups = nodes.flat_map { |node| slots.of(node) }.map(&:group)
    expect(groups).to eq([0, 1, 2])
    expect(slots.size).to eq(3)
  end

  it "gives each slot its expression and no pattern without a processor" do
    nodes = parse("x{/a}")
    slot = described_class.new(nodes).of(nodes.last).first
    expect(slot.expression).to equal(nodes.last)
    expect(slot.pattern).to be_nil
  end

  it "has no slots for a literal" do
    nodes = parse("x{a}")
    expect(described_class.new(nodes).of(nodes.first)).to eq([])
  end

  it "asks the processor for each varspec's pattern once, in order" do
    processor = SlotsSpecProcessor.new("b" => "[0-9]+")
    nodes = parse("{a,b}/{c}{?a}")
    slots = described_class.new(nodes, processor)
    expect(processor.asked).to eq(%w(a b c a))
    patterns = nodes.flat_map { |node| slots.of(node) }.map(&:pattern)
    expect(patterns).to eq([nil, "[0-9]+", nil, nil])
  end

  it "doesn't absorb an exploded variable with a pattern, or after one" do
    expect(roles("{/a*,b*}", SlotsSpecProcessor.new("b" => "x"))).to eq(
      [["a*", :own], ["b*", :own]]
    )
    expect(roles("{/a*,b*}", SlotsSpecProcessor.new("a" => "x"))).to eq(
      [["a*", :own], ["b*", :own]]
    )
  end

  it "doesn't match a name written again by its earlier value where " \
     "either has a pattern" do
    expect(roles("{a}/{a}", SlotsSpecProcessor.new("a" => "x"))).to eq(
      [["a", :own], ["a", :own]]
    )
  end
end

describe Addressable::Template::Machine::Slots, "#mapping" do
  # The mapping for the text each of the pattern's groups captured.
  def mapping(pattern, texts, processor = nil)
    nodes = Addressable::Template::Parser.new.parse_nodes(pattern)
    described_class.new(nodes).mapping(texts, processor)
  end

  {
    # A value as it is, decoded; nil for a group that took no part.
    ["{a}{/b}", ["x", nil]] => {"a" => "x", "b" => nil},
    ["{a}", ["%41%2F"]] => {"a" => "A/"},
    ["{+a}", ["a/b"]] => {"a" => "a/b"},
    ["{a}", [""]] => {"a" => ""},
    # An exploded value's members; empty text is one empty member.
    ["{/a*}", ["x/y"]] => {"a" => ["x", "y"]},
    ["{/a*}", ["x//"]] => {"a" => ["x", "", ""]},
    ["{/a*}", [""]] => {"a" => [""]},
    ["{/a*}", [nil]] => {"a" => nil},
    ["{.a*}", ["x.%41"]] => {"a" => ["x", "A"]},
    ["{a*}", ["x,y"]] => {"a" => ["x", "y"]},
    ["{+a*}", ["x,y/z"]] => {"a" => ["x", "y/z"]},
    ["{#a*}", ["x,y"]] => {"a" => ["x", "y"]},
    # A ;, ? or & value comes with its name.
    ["{?a}", ["a=1"]] => {"a" => "1"},
    ["{?a}", ["a="]] => {"a" => ""},
    ["{&a}", ["a=%41"]] => {"a" => "A"},
    ["{;a}", ["a"]] => {"a" => ""},
    ["{;a}", ["a=1"]] => {"a" => "1"},
    ["{?a}", [nil]] => {"a" => nil},
    # An exploded one is a list if every name is the variable's.
    ["{?a*}", ["a=1&a=2"]] => {"a" => ["1", "2"]},
    ["{?a*}", ["x=1&y=2"]] => {"a" => {"x" => "1", "y" => "2"}},
    ["{&a*}", ["a=1&y=2"]] => {"a" => {"a" => "1", "y" => "2"}},
    ["{;a*}", ["x;y=1"]] => {"a" => {"x" => "", "y" => "1"}},
    ["{;a*}", ["a;a=1"]] => {"a" => ["", "1"]},
    ["{?a*}", ["x=1=2"]] => {"a" => {"x" => "1=2"}},
    ["{?a*}", ["%41=%42"]] => {"a" => {"A" => "B"}},
    ["{?a*}", [""]] => {"a" => {"" => ""}},
    ["{;a*}", ["x;"]] => {"a" => {"x" => "", "" => ""}},
    ["{?a*}", [nil]] => {"a" => nil},
    # A name written again keeps its first value, unless that was nil.
    ["{a}{a}", ["x", "y"]] => {"a" => "x"},
    ["{a}{a}", [nil, "y"]] => {"a" => "y"},
    ["{a}{a}", [nil, nil]] => {"a" => nil},
    # A whole value replaces a prefix's.
    ["{/var:1,var}", ["v", "value"]] => {"var" => "value"},
    ["{/var:1,var}", ["v", nil]] => {"var" => "v"},
    ["{/var:1,var}", [nil, "value"]] => {"var" => "value"},
    ["{/var,var:1}", ["value", "v"]] => {"var" => "value"},
    ["{/a:1,a:2}", ["x", "xy"]] => {"a" => "x"},
    ["{/a:1,a,a}", ["x", "xy", "z"]] => {"a" => "xy"}
  }.each do |(pattern, texts), expected|
    it "gives #{pattern} with #{texts.inspect} #{expected.inspect}" do
      expect(mapping(pattern, texts)).to eq(expected)
    end
  end

  it "keeps the names in the order the pattern writes them" do
    expect(mapping("{b}{?a}{/b}", [nil, nil, "x"]).keys).to eq(%w(b a))
  end

  it "gives a ;, ? or & value the name its text has, which a " \
     "processor's pattern can make another" do
    expect(mapping("{?n}", ["12"])).to eq("n" => nil, "12" => "")
    expect(mapping("{?n}", ["k=v=w"])).to eq("n" => nil, "k" => "v")
  end

  it "restores each value with the processor, under its name" do
    processor = Class.new do
      def self.restore(name, value)
        [name, value]
      end
    end
    expect(mapping("{a}{/b*}{?c}", ["%41", "x/y", nil], processor)).to eq(
      "a" => ["a", "%41"], "b" => ["b", ["x", "y"]], "c" => ["c", nil]
    )
  end

  it "leaves values as the URI has them for a processor that " \
     "doesn't restore" do
    expect(mapping("{a}", ["%41"], Object.new)).to eq("a" => "%41")
  end
end
