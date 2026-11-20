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

require "addressable/template"

# The states the :machine engine builds for a template, as Matcher#to_s
# lists them. These pin one small template for each shape the nodes add,
# so a change to the graph shows up here as a diff to read. When a change
# is meant, print the new graph and replace the lines:
#
#   puts Addressable::Template::ParsedTemplate.new("{/a}").matcher
describe Addressable::Template::Matcher, "#to_s" do
  # A processor that gives the variable n a pattern.
  class MatcherSpecProcessor
    def self.match(name)
      name == "n" ? "[0-9]+" : nil
    end
  end

  def graph(pattern, processor = nil)
    parsed = Addressable::Template::ParsedTemplate.new(pattern)
    parsed.matcher(processor).to_s.split("\n").map(&:lstrip)
  end

  {
    # A value with no leader: left out if it takes nothing.
    "{a}" => [
      "0 Choice 1 or 6",
      "1 Capture group 0 start",
      "2 GreedyRun unreserved, stopping at its end",
      "3 LeaveOutIfEmpty to 6",
      "4 Capture group 0 end",
      "5 Jump to 7",
      "6 Jump to 7",
      "7 Done"
    ],
    # A value before literal text it could hold stops only before it.
    "{/a}.json" => [
      "0 Choice 1 or 5",
      "1 Literal \"/\"",
      "2 Capture group 0 start",
      "3 GreedyRun unreserved, stopping before \".json\"",
      "4 Capture group 0 end",
      "5 Literal \".json\"",
      "6 Done"
    ],
    # A non-ASCII literal in either form, and a value before one that
    # could take the end of its run.
    "é{/a}{b}" => [
      "0 Literal \"é\"|\"%C3%A9\"",
      "1 Choice 2 or 6",
      "2 Literal \"/\"",
      "3 Capture group 0 start",
      "4 GreedyRun unreserved, stopping at its end, or anywhere if the " \
        "end follows it",
      "5 Capture group 0 end",
      "6 Choice 7 or 12",
      "7 Capture group 1 start",
      "8 GreedyRun unreserved, stopping at its end",
      "9 LeaveOutIfEmpty to 12",
      "10 Capture group 1 end",
      "11 Jump to 13",
      "12 Jump to 13",
      "13 Done"
    ],
    # A leader that isn't the joiner: each variable after the leader, then
    # the later ones after the joiner.
    "{?a,b}" => [
      "0 Choice 1 or 7",
      "1 Literal \"?\"",
      "2 Capture group 0 start",
      "3 Literal \"a=\"",
      "4 GreedyRun unreserved, stopping at its end",
      "5 Capture group 0 end",
      "6 Jump to 15",
      "7 Choice 8 or 14",
      "8 Literal \"?\"",
      "9 Capture group 1 start",
      "10 Literal \"b=\"",
      "11 GreedyRun unreserved, stopping at its end",
      "12 Capture group 1 end",
      "13 Jump to 21",
      "14 Jump to 21",
      "15 Choice 16 or 21",
      "16 Literal \"&\"",
      "17 Capture group 1 start",
      "18 Literal \"b=\"",
      "19 GreedyRun unreserved, stopping at its end",
      "20 Capture group 1 end",
      "21 Done"
    ],
    # No leader: an empty first value is left out, unless a joiner follows
    # it.
    "{a,b}" => [
      "0 Choice 1 or 6",
      "1 Capture group 0 start",
      "2 GreedyRun unreserved",
      "3 LeaveOutIfEmpty to 6",
      "4 Capture group 0 end",
      "5 Jump to 17",
      "6 Choice 7 or 10",
      "7 Capture group 0 start",
      "8 Capture group 0 end",
      "9 Jump to 18",
      "10 Choice 11 or 16",
      "11 Capture group 1 start",
      "12 GreedyRun unreserved, stopping at its end",
      "13 LeaveOutIfEmpty to 16",
      "14 Capture group 1 end",
      "15 Jump to 22",
      "16 Jump to 22",
      "17 Choice 18 or 22",
      "18 Literal \",\"",
      "19 Capture group 1 start",
      "20 GreedyRun unreserved, stopping at its end",
      "21 Capture group 1 end",
      "22 Done"
    ],
    # A value stops before the last place the next expression's leader
    # follows it, then anywhere (rule 3).
    "/{name}{.ext}" => [
      "0 Literal \"/\"",
      "1 Choice 2 or 11",
      "2 Capture group 0 start",
      "3 Choice 4 or 7",
      "4 GreedyRun unreserved",
      "5 FollowedBy \".\"",
      "6 Jump to 8",
      "7 GreedyRun unreserved",
      "8 LeaveOutIfEmpty to 11",
      "9 Capture group 0 end",
      "10 Jump to 12",
      "11 Jump to 12",
      "12 Choice 13 or 17",
      "13 Literal \".\"",
      "14 Capture group 1 start",
      "15 GreedyRun unreserved_no_dot, stopping at its end",
      "16 Capture group 1 end",
      "17 Done"
    ],
    # A + value stops at the first "?" or "#" (rule 2), inside rule 3.
    "{+a}{?q}" => [
      "0 Choice 1 or 16",
      "1 Capture group 0 start",
      "2 Choice 3 or 9",
      "3 Choice 4 or 6",
      "4 DelimiterRun reserved",
      "5 Jump to 7",
      "6 GreedyRun reserved",
      "7 FollowedBy \"?\"",
      "8 Jump to 13",
      "9 Choice 10 or 12",
      "10 DelimiterRun reserved",
      "11 Jump to 13",
      "12 GreedyRun reserved",
      "13 LeaveOutIfEmpty to 16",
      "14 Capture group 0 end",
      "15 Jump to 17",
      "16 Jump to 17",
      "17 Choice 18 or 24",
      "18 Literal \"?\"",
      "19 Capture group 1 start",
      "20 Literal \"q=\"",
      "21 GreedyRun unreserved, stopping at its end",
      "22 Capture group 1 end",
      "23 Jump to 25",
      "24 Jump to 25",
      "25 Done"
    ],
    # A "#" that may be written "%23", once a fragment may have started.
    "{#a}x{#b}" => [
      "0 Choice 1 or 9",
      "1 Literal \"#\"",
      "2 Capture group 0 start",
      "3 Choice 4 or 6",
      "4 DelimiterRun reserved",
      "5 Jump to 7",
      "6 GreedyRun reserved",
      "7 Capture group 0 end",
      "8 Jump to 10",
      "9 Jump to 10",
      "10 Literal \"x\"",
      "11 Choice 12 or 20",
      "12 Literal \"#\"|\"%23\"",
      "13 Capture group 1 start",
      "14 Choice 15 or 17",
      "15 DelimiterRun reserved",
      "16 Jump to 18",
      "17 GreedyRun reserved, stopping at its end",
      "18 Capture group 1 end",
      "19 Jump to 21",
      "20 Jump to 21",
      "21 Done"
    ],
    # An exploded value: members with the joiner between them.
    "{/a*}" => [
      "0 Choice 1 or 9",
      "1 Literal \"/\"",
      "2 Capture group 0 start",
      "3 GreedyRun unreserved, stopping at its end",
      "4 Choice 5 or 8",
      "5 Literal \"/\"",
      "6 GreedyRun unreserved, stopping at its end",
      "7 Jump to 4",
      "8 Capture group 0 end",
      "9 Done"
    ],
    # An exploded value stops before a later variable's name (rule 1).
    "{&a*,b}" => [
      "0 Choice 1 or 3",
      "1 FollowedBy \"&b\"",
      "2 Jump to 27",
      "3 Choice 4 or 27",
      "4 Literal \"&\"",
      "5 Capture group 0 start",
      "6 GreedyRun unreserved, stopping at its end",
      "7 Literal \"=\"",
      "8 Choice 9 or 12",
      "9 GreedyRun unreserved, stopping at its end",
      "10 Literal \"=\"",
      "11 Jump to 8",
      "12 GreedyRun unreserved, stopping at its end",
      "13 Choice 14 or 16",
      "14 FollowedBy \"&b\"",
      "15 Jump to 26",
      "16 Choice 17 or 26",
      "17 Literal \"&\"",
      "18 GreedyRun unreserved, stopping at its end",
      "19 Literal \"=\"",
      "20 Choice 21 or 24",
      "21 GreedyRun unreserved, stopping at its end",
      "22 Literal \"=\"",
      "23 Jump to 20",
      "24 GreedyRun unreserved, stopping at its end",
      "25 Jump to 13",
      "26 Capture group 0 end",
      "27 Choice 28 or 33",
      "28 Literal \"&\"",
      "29 Capture group 1 start",
      "30 Literal \"b=\"",
      "31 GreedyRun unreserved, stopping at its end",
      "32 Capture group 1 end",
      "33 Done"
    ],
    # A ; value: the name, then "=" and a value that isn't empty, or
    # nothing.
    "{;a}" => [
      "0 Choice 1 or 9",
      "1 Literal \";\"",
      "2 Capture group 0 start",
      "3 Literal \"a\"",
      "4 Choice 5 or 8",
      "5 Literal \"=\"",
      "6 OneCharacter unreserved",
      "7 GreedyRun unreserved, stopping at its end",
      "8 Capture group 0 end",
      "9 Done"
    ],
    # An exploded variable right after another gets a group and no states.
    "{;a*,b*}" => [
      "0 Choice 1 or 17",
      "1 Literal \";\"",
      "2 Capture group 0 start",
      "3 GreedyRun unreserved, stopping at its end",
      "4 Choice 5 or 8",
      "5 Literal \"=\"",
      "6 OneCharacter unreserved_or_equals",
      "7 GreedyRun unreserved_or_equals, stopping at its end",
      "8 Choice 9 or 16",
      "9 Literal \";\"",
      "10 GreedyRun unreserved, stopping at its end",
      "11 Choice 12 or 15",
      "12 Literal \"=\"",
      "13 OneCharacter unreserved_or_equals",
      "14 GreedyRun unreserved_or_equals, stopping at its end",
      "15 Jump to 8",
      "16 Capture group 0 end",
      "17 Done"
    ],
    # A label that can hold dots takes its whole run.
    "/{.d}/" => [
      "0 Literal \"/\"",
      "1 Choice 2 or 6",
      "2 Literal \".\"",
      "3 Capture group 0 start",
      "4 PossessiveRun unreserved",
      "5 Capture group 0 end",
      "6 Literal \"/\"",
      "7 Done"
    ],
    # A name written again matches the earlier value, and the states
    # between are remembered once for each place that value took.
    "{a}/{a}" => [
      "0 Choice 1 or 6",
      "1 Capture group 0 start",
      "2 GreedyRun unreserved, stopping at its end",
      "3 LeaveOutIfEmpty to 6",
      "4 Capture group 0 end",
      "5 Jump to 7",
      "6 Jump to 7",
      "7 Literal \"/\"",
      "8 Choice 9 or 15 (once for each place of group 0)",
      "9 Capture group 1 start",
      "10 SameValue as group 0",
      "11 LeaveOutIfEmpty to 16",
      "12 Capture group 1 end",
      "13 Jump to 17",
      "14 Jump to 16",
      "15 LeftOut as group 0",
      "16 Jump to 17",
      "17 Done"
    ],
    # After a prefix, the name matches a value of its own that starts with
    # the earlier one.
    "{/var:1,var}" => [
      "0 Choice 1 or 5",
      "1 Literal \"/\"",
      "2 Capture group 0 start",
      "3 GreedyRun unreserved, stopping at its end",
      "4 Capture group 0 end",
      "5 Choice 6 or 12 (once for each place of group 0)",
      "6 Literal \"/\"",
      "7 Capture group 1 start",
      "8 GreedyRun unreserved, stopping at its end (once for each place " \
        "of group 0)",
      "9 Capture group 1 end",
      "10 StartsWith group 1 with group 0",
      "11 Jump to 13",
      "12 LeftOut as group 0",
      "13 Done"
    ]
  }.each do |pattern, expected|
    it "lists the states of #{pattern}" do
      expect(graph(pattern)).to eq(expected)
    end
  end

  it "lists a processor's pattern" do
    expect(graph("{n}", MatcherSpecProcessor)).to eq([
      "0 Choice 1 or 6",
      "1 Capture group 0 start",
      "2 ProcessorPattern /[0-9]+/",
      "3 LeaveOutIfEmpty to 6",
      "4 Capture group 0 end",
      "5 Jump to 7",
      "6 Jump to 7",
      "7 Done"
    ])
  end

  it "lines up the numbers of a graph with ten states or more" do
    lines = Addressable::Template::ParsedTemplate.new("{?a,b}").matcher.
      to_s.split("\n")
    expect(lines.first).to eq(" 0 Choice 1 or 7")
    expect(lines.last).to eq("21 Done")
  end

  it "raises the template's error for a pattern that isn't valid" do
    parsed = Addressable::Template::ParsedTemplate.new("{a")
    expect { parsed.matcher }.to raise_error(
      Addressable::Template::InvalidTemplateError
    )
  end
end

# The builder methods the nodes call, on matchers built by hand, so that
# what each one does can be read and tried apart from the operators.
describe Addressable::Template::Matcher, "builder methods" do
  def build(groups)
    matcher = described_class.new(groups)
    yield matcher
    matcher.finish
  end

  def captures(matcher, text)
    matched = matcher.match(text)
    matched && matched.captures
  end

  it "#greedy_run takes as much as it can, and gives back what the " \
     "rest needs" do
    matcher = build(1) do |m|
      m.capture(0) { m.greedy_run(:unreserved) }
      m.exact("b")
    end
    expect(captures(matcher, "abab")).to eq(["aba"])
    expect(captures(matcher, "b")).to eq([""])
    expect(captures(matcher, "aba")).to be_nil
  end

  it "#possessive_run gives nothing back" do
    matcher = build(1) do |m|
      m.capture(0) { m.possessive_run(:unreserved) }
      m.exact("b")
    end
    expect(captures(matcher, "ab")).to be_nil
    expect(captures(matcher, "a/b")).to be_nil
  end

  it "#one_character takes one character of the set, however it's " \
     "written" do
    matcher = build(1) do |m|
      m.capture(0) { m.one_character(:unreserved) }
    end
    expect(captures(matcher, "a")).to eq(["a"])
    expect(captures(matcher, "%41")).to eq(["%41"])
    expect(captures(matcher, "é")).to eq(["é"])
    expect(captures(matcher, "ab")).to be_nil
    expect(captures(matcher, "/")).to be_nil
    expect(captures(matcher, "")).to be_nil
  end

  it "#optional tries its states, then nothing" do
    matcher = build(1) do |m|
      m.optional do
        m.exact("/")
        m.capture(0) { m.greedy_run(:unreserved) }
      end
    end
    expect(captures(matcher, "/a")).to eq(["a"])
    expect(captures(matcher, "/")).to eq([""])
    expect(captures(matcher, "")).to eq([nil])
  end

  it "#leave_out_if_empty drops a value that took nothing" do
    matcher = build(1) do |m|
      left_out = []
      m.optional do
        m.capture(0) do
          m.greedy_run(:unreserved)
          left_out << m.leave_out_if_empty
        end
      end
      m.land(left_out)
      m.exact("/")
    end
    expect(captures(matcher, "a/")).to eq(["a"])
    expect(captures(matcher, "/")).to eq([nil])
  end

  it "#repeat takes members with the joiner between them" do
    matcher = build(1) do |m|
      m.capture(0) do
        m.repeat("/") { m.greedy_run(:unreserved) }
      end
    end
    expect(captures(matcher, "a/b/c")).to eq(["a/b/c"])
    expect(captures(matcher, "a//")).to eq(["a//"])
    expect(captures(matcher, "")).to eq([""])
    expect(captures(matcher, "a/b?")).to be_nil
  end

  context "#preferring_followed_by" do
    let(:matcher) do
      build(2) do |m|
        m.capture(0) do
          m.preferring_followed_by(["."]) { m.greedy_run(:unreserved) }
        end
        m.optional do
          m.exact(".")
          m.capture(1) { m.greedy_run(:unreserved) }
        end
      end
    end

    it "stops before the last place the text follows" do
      expect(captures(matcher, "a.b.c")).to eq(["a.b", "c"])
      expect(captures(matcher, "a.")).to eq(["a", ""])
    end

    it "takes everything where the text doesn't follow" do
      expect(captures(matcher, "abc")).to eq(["abc", nil])
    end

    it "stops at an earlier place where the rest can't match from " \
       "the last" do
      strict = build(2) do |m|
        m.capture(0) do
          m.preferring_followed_by(["."]) { m.greedy_run(:unreserved) }
        end
        m.exact(".")
        m.capture(1) { m.one_character(:unreserved) }
      end
      expect(captures(strict, "a.b.")).to be_nil
      expect(captures(strict, "a.b.c")).to eq(["a.b", "c"])
      expect(captures(strict, "a..b")).to eq(["a.", "b"])
    end
  end

  context "#reserved_run" do
    let(:matcher) do
      build(2) do |m|
        m.capture(0) { m.reserved_run(:reserved) }
        m.optional do
          m.exact("?")
          m.capture(1) { m.greedy_run(:reserved) }
        end
      end
    end

    it "stops at the first \"?\" where the rest can match" do
      expect(captures(matcher, "a/b?c?d")).to eq(["a/b", "c?d"])
    end

    it "takes everything where there's none" do
      expect(captures(matcher, "a/b")).to eq(["a/b", nil])
    end

    it "stops at a later one, or takes them all, where the rest can't " \
       "match from the first" do
      strict = build(1) do |m|
        m.capture(0) { m.reserved_run(:reserved) }
        m.exact("?x")
      end
      expect(captures(strict, "a?b?x")).to eq(["a?b"])
      expect(captures(strict, "a#b?x")).to eq(["a#b"])
      expect(captures(strict, "a?b")).to be_nil
      whole = build(1) { |m| m.capture(0) { m.reserved_run(:reserved) } }
      expect(captures(whole, "a?b#c")).to eq(["a?b#c"])
    end
  end

  context "#optional_unless_followed_by" do
    let(:matcher) do
      build(2) do |m|
        m.optional_unless_followed_by(["&b="]) do
          m.exact("&")
          m.capture(0) do
            m.greedy_run(:unreserved)
            m.exact("=")
            m.greedy_run(:unreserved)
          end
        end
        m.optional do
          m.exact("&b=")
          m.capture(1) { m.greedy_run(:unreserved) }
        end
      end
    end

    it "leaves its states out where the text follows" do
      expect(captures(matcher, "&b=1")).to eq([nil, "1"])
    end

    it "tries its states where it doesn't" do
      expect(captures(matcher, "&x=1&b=2")).to eq(["x=1", "2"])
      expect(captures(matcher, "&x=1")).to eq(["x=1", nil])
      expect(captures(matcher, "")).to eq([nil, nil])
    end

    it "tries its states where the rest can't match without them" do
      expect(captures(matcher, "&b=1&b=2")).to eq(["b=1", "2"])
    end
  end

  context "#repeat_stopping_before" do
    let(:matcher) do
      build(2) do |m|
        m.exact("?")
        m.capture(0) do
          m.repeat_stopping_before("&", ["&b="]) do
            m.greedy_run(:unreserved)
            m.exact("=")
            m.greedy_run(:unreserved)
          end
        end
        m.optional do
          m.exact("&b=")
          m.capture(1) { m.greedy_run(:unreserved) }
        end
      end
    end

    it "stops after the first member the text follows" do
      expect(captures(matcher, "?x=1&y=2&b=3")).to eq(["x=1&y=2", "3"])
    end

    it "takes every member where it doesn't" do
      expect(captures(matcher, "?x=1&y=2")).to eq(["x=1&y=2", nil])
    end

    it "goes on to a later place where the rest can't match from " \
       "the first" do
      expect(captures(matcher, "?x=1&b=3&b=4")).to eq(["x=1&b=3", "4"])
    end
  end

  it "#processor_pattern tries the pattern's first choice, then the " \
     "ends nearest it" do
    matcher = build(2) do |m|
      m.capture(0) { m.processor_pattern("[0-9]+") }
      m.capture(1) { m.greedy_run(:unreserved) }
    end
    expect(captures(matcher, "12ab")).to eq(["12", "ab"])
    expect(captures(matcher, "ab")).to be_nil
    needs_digit = build(2) do |m|
      m.capture(0) { m.processor_pattern("[0-9]+") }
      m.capture(1) { m.one_character(:unreserved) }
    end
    expect(captures(needs_digit, "123")).to eq(["12", "3"])
  end

  it "gives nil for a group nothing captured" do
    matcher = build(3) do |m|
      m.capture(1) { m.greedy_run(:unreserved) }
    end
    expect(captures(matcher, "a")).to eq([nil, "a", nil])
  end
end

describe Addressable::Template::Matcher::FirstBytes, "#to_s" do
  matcher = Addressable::Template::Matcher

  it "lists visible ASCII characters as they are" do
    expect(described_class.bytes(47, 63).to_s).to eq("\"/?\"")
  end

  it "says when there are other bytes, and the end of the URI" do
    expect(described_class.bytes(32).to_s).to eq("other bytes")
    expect(described_class.bytes(97, 200).to_s).to eq("\"a\", other bytes")
    expect(matcher::ONLY_END_OF_URI.to_s).to eq("the end")
    expect(described_class.bytes(61, 256).to_s).to eq("\"=\", the end")
  end

  it "says when there are none" do
    expect(matcher::NOTHING.to_s).to eq("nothing")
  end
end
