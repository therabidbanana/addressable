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

require "timeout"
require "addressable/template"

describe Addressable::Template::Parser do
  machine = Addressable::Template::Machine

  # Each node as a literal's text, or [operator class, [name, explode,
  # prefix] for each variable].
  def nodes(pattern)
    described_class.new.parse_nodes(pattern).map do |node|
      if node.is_a?(Addressable::Template::Machine::Literal)
        next node.pattern_text
      end
      [node.class, node.variables.map { |v| [v.name, v.explode, v.prefix] }]
    end
  end

  {
    "" => [],
    "a/b" => ["a/b"],
    "{a}" => [[machine::OpPlain, [["a", false, nil]]]],
    "x{+a}y" => ["x", [machine::OpReserved, [["a", false, nil]]], "y"],
    "{#a}" => [[machine::OpFragment, [["a", false, nil]]]],
    "{.a}" => [[machine::OpLabel, [["a", false, nil]]]],
    "{/a}" => [[machine::OpPath, [["a", false, nil]]]],
    "{;a}" => [[machine::OpPathParams, [["a", false, nil]]]],
    "{?a}" => [[machine::OpForm, [["a", false, nil]]]],
    "{&a}" => [[machine::OpFormContinuation, [["a", false, nil]]]],
    "{a*,b:3,c}" => [[machine::OpPlain, [
      ["a", true, nil], ["b", false, 3], ["c", false, nil]
    ]]],
    "{a:9999}" => [[machine::OpPlain, [["a", false, 9999]]]],
    "{42}" => [[machine::OpPlain, [["42", false, nil]]]],
    "{%41b}" => [[machine::OpPlain, [["%41b", false, nil]]]],
    # A non-ASCII name is written pct-encoded (RFC 6570 section 2.3).
    "{%C3%A9}" => [[machine::OpPlain, [["%C3%A9", false, nil]]]],
    "{a.b.c}" => [[machine::OpPlain, [["a.b.c", false, nil]]]],
    "{a_1}" => [[machine::OpPlain, [["a_1", false, nil]]]],
    "é{a}é" => ["é", [machine::OpPlain, [["a", false, nil]]], "é"]
  }.each do |pattern, expected|
    it "lexes #{pattern.inspect}" do
      expect(nodes(pattern)).to eq(expected)
    end
  end

  # The :machine engine raises the error Template raises, with the same
  # message, from the first operation that needs a valid pattern.
  [
    "{", "}", "{a", "a}", "{}", "{{a}}", "{a}{", "}{a}", "{a}}",
    "{/?a}", "{a b}", "{ a}", "{a }", "{$a}", "{*a?}", "{a-b}", "{~a}",
    "{a:0}", "{a:01}", "{a:10000}", "{a:}", "{a:x}", "{a:2*}", "{a*:2}",
    "{a*,}", "{a,}", "{a,,b}", "{a.}", "{.a.}", "{a..b}", "{%2x}", "{%}",
    "{a)}", "{?a){&b*}",
    "{!a}", "{=a}", "{,a}", "{@a}", "{|a}", "/{@a}",
    "é{!a}", "éé}", "{é}", "{a,é}", "{a}{!b}{c}", "{!a}{b", "{a}{b c}{!d}",
    # Valid expressions between non-ASCII text, so the error's position
    # depends on counting each one's length in characters.
    "é{a}é{%C3%A9:3}é{+b*,c}é{!d}", "{a:١}", "{a:٣}",
    # A valid expression at the end of an invalid token, which Template
    # still lists in #variables, unless its operator is reserved.
    "{a{b}", "{!{a}", "{{!a}", "{?a){=b}", "{a,{b,c}{d}", "{%{a*}x{"
  ].each do |pattern|
    it "raises Template's error for #{pattern.inspect}" do
      regexp = Addressable::Template.new(pattern, engine: :regexp)
      expected = begin
        regexp.expand({})
        raise "#{pattern.inspect} is valid for the :regexp engine"
      rescue Addressable::Template::InvalidTemplateError => e
        e
      end
      template = Addressable::Template.new(pattern, engine: :machine)
      expect(template.freeze).to be_frozen
      [lambda { template.expand({}) }, lambda { template.match("") }].each do
        |operation|
        expect(&operation).to raise_error(expected.class, expected.message)
      end
    end

    it "lists Template's variables for #{pattern.inspect}" do
      regexp = Addressable::Template.new(pattern, engine: :regexp)
      template = Addressable::Template.new(pattern, engine: :machine)
      expect(template.variables).to eq(regexp.variables)
      expect(template.variable_defaults).to eq(regexp.variable_defaults)
    end
  end

  [
    "", "a/b", "{a}", "{a}{b}{a}", "{a,b,a}", "{+a}{#b}{.c}{/d}{;e}{?f}{&g}",
    "{a*,b:3}", "{42}", "{%41b}", "{a.b}", "{%C3%A9}", "x{a}y{b}{a}z",
    "a\xFF{a}".b
  ].each do |pattern|
    it "lists Template's variables for the valid #{pattern.inspect}" do
      regexp = Addressable::Template.new(pattern, engine: :regexp)
      template = Addressable::Template.new(pattern, engine: :machine)
      expect(template.variables).to eq(regexp.variables)
      expect(template.keys).to eq(regexp.variables)
      expect(template.names).to eq(regexp.variables)
      expect(template.variable_defaults).to eq({})
    end
  end

  # A pattern in an ASCII-compatible encoding lexes in that encoding, with
  # its literal bytes as they are.
  {
    "binary" => "a\xFF{a}".b,
    "binary that is valid UTF-8" => "caf\xC3\xA9{a}".b,
    "ISO-8859-1" => "a b\xE9{a}".dup.force_encoding("ISO-8859-1"),
    "Shift_JIS" => "日{a}".encode("Shift_JIS"),
    "US-ASCII" => "x/{a}".dup.force_encoding("US-ASCII")
  }.each do |label, pattern|
    it "lexes a #{label} pattern" do
      literal = pattern[0, pattern.index("{")]
      lexed = nodes(pattern)
      expect(lexed).to eq([literal, [machine::OpPlain, [["a", false, nil]]]])
      expect(lexed.first.encoding).to eq(pattern.encoding)
    end
  end

  # Template raises these from freeze and every operation; so does the
  # :machine engine.
  {
    "UTF-8 that isn't valid" => "a\xFF{a}".dup.force_encoding("UTF-8"),
    "UTF-8 that isn't valid, in an expression" =>
      "{a\xFF}".dup.force_encoding("UTF-8"),
    "Shift_JIS that isn't valid" => "\x81{a}".dup.force_encoding("Shift_JIS"),
    "UTF-16LE" => "x/{a}".encode("UTF-16LE")
  }.each do |label, pattern|
    it "raises Template's error for a #{label} pattern" do
      outcome = lambda do |engine|
        [
          lambda { Addressable::Template.new(pattern, engine: engine).freeze },
          lambda { Addressable::Template.new(pattern, engine: engine).expand({}) },
          lambda { Addressable::Template.new(pattern, engine: engine).match("") }
        ].map do |operation|
          begin
            operation.call
            :no_error
          rescue StandardError => e
            [e.class, e.message]
          end
        end
      end
      expected = outcome.call(:regexp)
      expect(expected.last).not_to eq(:no_error)
      expect(outcome.call(:machine)).to eq(expected)
    end
  end

  it "lexes long patterns with non-ASCII literals in linear time" do
    # Compared with ASCII literals on the same runner, so that a slow or
    # busy runner doesn't fail the spec. Counting each position in
    # characters from the start, which is quadratic, took over ten times as
    # long at this size.
    size = 30_000
    fastest = lambda do |pattern|
      3.times.map do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        described_class.new.parse_nodes(pattern)
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end.min
    end
    ascii_time = fastest.call(("a{a}" * size) + "}")
    non_ascii_time = fastest.call(("é{a}" * size) + "}")
    expect(non_ascii_time).to be < (ascii_time * 4) + 0.05
  end

  describe "placing the nodes" do
    def parse(pattern)
      described_class.new.parse_nodes(pattern)
    end

    it "links each node to the one after it" do
      first, second, third = parse("{a}x{b}")
      expect(first.following).to equal(second)
      expect(second.following).to equal(third)
      expect(third.following).to be_nil
    end

    it "notes whether a fragment may have started before each node" do
      expect(parse('a{b}#c{#d}').map(&:fragment)).
        to eq([false, false, false, true])
      expect(parse('{+a}#{#b}').map(&:fragment)).to eq([false, true, true])
    end

    # The next node's answer comes from the nodes after it, which the
    # parser hasn't read when it adds the node.
    it "notes whether a comma may start at each expression" do
      reserved, label, _comma = parse("{+a,b}{.x},")
      expect(label.comma_may_start_here?).to be true
      expect(reserved.comma_follows?).to be true
      reserved, label, _x = parse("{+a,b}{.x}x")
      expect(label.comma_may_start_here?).to be false
      expect(reserved.comma_follows?).to be false
      expect(parse("{+a,b}").first.comma_follows?).to be false
    end

    it "notes whether a label's value can contain \".\"" do
      expect(parse("/{.d}/")[1].label_dots).to be true
      expect(parse("/{.d}{e}")[1].label_dots).to be false
    end

    # Nothing walks an invalid pattern's nodes, so they aren't linked.
    it "doesn't link the nodes of a pattern with an invalid token" do
      expect(parse("{a}{!b}").first.following).to be_nil
    end
  end

  it "parses long patterns in linear time" do
    [
      ("{#a,b}" * 30_000),
      "/{.a}" + ("{/b}" * 30_000),
      "{" * 100_000,
      "}" * 100_000,
      "{a" * 50_000,
      "{" + ("a." * 50_000) + "}",
      "{" + ("a," * 50_000) + "!}",
      "{" + ("%2" * 50_000) + "}",
      ("{a}" * 30_000) + "{",
      ("é{a}" * 30_000) + "}",
      ("é" * 100_000) + "{é}",
      "{" + ("a" * 100_000) + ":1}",
      ("{a*}" * 30_000),
      # Each "{" in an invalid token is tried as the start of an expression.
      ("{a" * 50_000) + "}",
      ("{!" * 50_000) + "a}",
      "{" + ("a,{" * 30_000) + "a}"
    ].each do |pattern|
      expect do
        Timeout.timeout(10) { described_class.new.parse_nodes(pattern) }
      end.not_to raise_error
    end
  end
end
