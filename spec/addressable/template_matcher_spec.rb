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
      "2 GreedyRun unreserved_or_comma, stopping at its end",
      "3 LeaveOutIfEmpty to 6",
      "4 Capture group 0 end",
      "5 Jump to 7",
      "6 Jump to 7",
      "7 Done"
    ],
    # A value before literal text it could hold stops only before it,
    # whether or not it has a leader.
    "{a}.json" => [
      "0 Choice 1 or 6",
      "1 Capture group 0 start",
      "2 GreedyRun unreserved_or_comma, stopping before \".json\"",
      "3 LeaveOutIfEmpty to 6",
      "4 Capture group 0 end",
      "5 Jump to 7",
      "6 Jump to 7",
      "7 Literal \".json\"",
      "8 Done"
    ],
    "{/a}.json" => [
      "0 Choice 1 or 5",
      "1 Literal \"/\"",
      "2 Capture group 0 start",
      "3 GreedyRun unreserved_or_comma, stopping before \".json\"",
      "4 Capture group 0 end",
      "5 Literal \".json\"",
      "6 Done"
    ],
    # A non-ASCII literal in either form, and a value before one that
    # could take the end of its run: it stops at its end, or anywhere if
    # the template's end follows.
    "é{/a}{b}" => [
      "0 Literal \"é\"|\"%C3%A9\"",
      "1 Choice 2 or 6",
      "2 Literal \"/\"",
      "3 Capture group 0 start",
      "4 GreedyRun unreserved_or_comma, stopping at its end, or anywhere " \
        "if the end follows it",
      "5 Capture group 0 end",
      "6 Choice 7 or 12",
      "7 Capture group 1 start",
      "8 GreedyRun unreserved_or_comma, stopping at its end",
      "9 LeaveOutIfEmpty to 12",
      "10 Capture group 1 end",
      "11 Jump to 13",
      "12 Jump to 13",
      "13 Done"
    ],
    # A variable that can never take a character has no states for a
    # value: only those for an empty one, where a joiner follows it.
    "{a}{b}" => [
      "0 Choice 1 or 6",
      "1 Capture group 0 start",
      "2 GreedyRun unreserved_or_comma, stopping at its end",
      "3 LeaveOutIfEmpty to 6",
      "4 Capture group 0 end",
      "5 Jump to 7",
      "6 Jump to 7",
      "7 Jump to 8",
      "8 Done"
    ],
    # A leader that isn't the joiner: each variable after the leader, then
    # the later ones after the joiner.
    "{?a,b}" => [
      "0 Choice 1 or 7",
      "1 Literal \"?\"",
      "2 Capture group 0 start",
      "3 Literal \"a=\"",
      "4 GreedyRun unreserved_or_comma, stopping at its end",
      "5 Capture group 0 end",
      "6 Jump to 15",
      "7 Choice 8 or 14",
      "8 Literal \"?\"",
      "9 Capture group 1 start",
      "10 Literal \"b=\"",
      "11 GreedyRun unreserved_or_comma, stopping at its end",
      "12 Capture group 1 end",
      "13 Jump to 21",
      "14 Jump to 21",
      "15 Choice 16 or 21",
      "16 Literal \"&\"",
      "17 Capture group 1 start",
      "18 Literal \"b=\"",
      "19 GreedyRun unreserved_or_comma, stopping at its end",
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
      "12 GreedyRun unreserved_or_comma, stopping at its end",
      "13 LeaveOutIfEmpty to 16",
      "14 Capture group 1 end",
      "15 Jump to 22",
      "16 Jump to 22",
      "17 Choice 18 or 22",
      "18 Literal \",\"",
      "19 Capture group 1 start",
      "20 GreedyRun unreserved_or_comma, stopping at its end",
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
      "4 GreedyRun unreserved_or_comma, stopping before \".\"",
      "5 FollowedBy \".\"",
      "6 Jump to 8",
      "7 GreedyRun unreserved_or_comma",
      "8 LeaveOutIfEmpty to 11",
      "9 Capture group 0 end",
      "10 Jump to 12",
      "11 Jump to 12",
      "12 Choice 13 or 17",
      "13 Literal \".\"",
      "14 Capture group 1 start",
      "15 GreedyRun unreserved_no_dot_or_comma, stopping at its end",
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
      "6 GreedyRun reserved, stopping before \"?\"",
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
      "21 GreedyRun unreserved_or_comma, stopping at its end",
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
      "6 GreedyRun reserved, stopping before \"x\"",
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
    # An exploded value: members with the joiner between them, which are
    # all values (a list), or else all pairs (an associative array).
    "{/a*}" => [
      "0 Choice 1 or 20",
      "1 Literal \"/\"",
      "2 Capture group 0 start",
      "3 Choice 4 or 10",
      "4 GreedyRun unreserved, stopping at its end",
      "5 Choice 6 or 9",
      "6 Literal \"/\"",
      "7 GreedyRun unreserved, stopping at its end",
      "8 Jump to 5",
      "9 Jump to 19",
      "10 GreedyRun unreserved, stopping at its end",
      "11 Literal \"=\"",
      "12 GreedyRun unreserved, stopping at its end",
      "13 Choice 14 or 19",
      "14 Literal \"/\"",
      "15 GreedyRun unreserved, stopping at its end",
      "16 Literal \"=\"",
      "17 GreedyRun unreserved, stopping at its end",
      "18 Jump to 13",
      "19 Capture group 0 end",
      "20 Done"
    ],
    # A + or # member holds "=" as it is, so it has no pairs.
    "{+a*}" => [
      "0 Choice 1 or 16",
      "1 Capture group 0 start",
      "2 Choice 3 or 5",
      "3 DelimiterRun reserved_no_comma",
      "4 Jump to 6",
      "5 GreedyRun reserved_no_comma, stopping at its end",
      "6 Choice 7 or 13",
      "7 Literal \",\"",
      "8 Choice 9 or 11",
      "9 DelimiterRun reserved_no_comma",
      "10 Jump to 12",
      "11 GreedyRun reserved_no_comma, stopping at its end",
      "12 Jump to 6",
      "13 LeaveOutIfEmpty to 16",
      "14 Capture group 0 end",
      "15 Jump to 17",
      "16 Jump to 17",
      "17 Done"
    ],
    # An exploded value stops before a later variable's name (rule 1).
    "{&a*,b}" => [
      "0 Choice 1 or 3",
      "1 FollowedBy \"&b\"",
      "2 Jump to 29",
      "3 Choice 4 or 29",
      "4 Literal \"&\"",
      "5 Capture group 0 start",
      "6 GreedyRun unreserved, stopping at its end",
      "7 Literal \"=\"",
      "8 Choice 9 or 10",
      "9 Jump to 13",
      "10 GreedyRun unreserved, stopping at its end",
      "11 Literal \"=\"",
      "12 Jump to 8",
      "13 GreedyRun unreserved, stopping at its end",
      "14 Choice 15 or 17",
      "15 FollowedBy \"&b\"",
      "16 Jump to 28",
      "17 Choice 18 or 28",
      "18 Literal \"&\"",
      "19 GreedyRun unreserved, stopping at its end",
      "20 Literal \"=\"",
      "21 Choice 22 or 23",
      "22 Jump to 26",
      "23 GreedyRun unreserved, stopping at its end",
      "24 Literal \"=\"",
      "25 Jump to 21",
      "26 GreedyRun unreserved, stopping at its end",
      "27 Jump to 14",
      "28 Capture group 0 end",
      "29 Choice 30 or 35",
      "30 Literal \"&\"",
      "31 Capture group 1 start",
      "32 Literal \"b=\"",
      "33 GreedyRun unreserved_or_comma, stopping at its end",
      "34 Capture group 1 end",
      "35 Done"
    ],
    # A ; value: the name, then "=" and a value, or nothing. The value can
    # be empty, for a list of one empty member.
    "{;a}" => [
      "0 Choice 1 or 8",
      "1 Literal \";\"",
      "2 Capture group 0 start",
      "3 Literal \"a\"",
      "4 Choice 5 or 7",
      "5 Literal \"=\"",
      "6 GreedyRun unreserved_or_comma, stopping at its end",
      "7 Capture group 0 end",
      "8 Done"
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
      "4 PossessiveRun unreserved_or_comma",
      "5 Capture group 0 end",
      "6 Literal \"/\"",
      "7 Done"
    ],
    # A prefix takes at most its length.
    "{a:3}" => [
      "0 Choice 1 or 6",
      "1 Capture group 0 start",
      "2 CappedRun unreserved, at most 3",
      "3 LeaveOutIfEmpty to 6",
      "4 Capture group 0 end",
      "5 Jump to 7",
      "6 Jump to 7",
      "7 Done"
    ],
    # A ; value with a prefix isn't empty after its "=".
    "{;a:2}" => [
      "0 Choice 1 or 8",
      "1 Literal \";\"",
      "2 Capture group 0 start",
      "3 Literal \"a\"",
      "4 Choice 5 or 7",
      "5 Literal \"=\"",
      "6 CappedRun unreserved, at most 2, at least 1",
      "7 Capture group 0 end",
      "8 Done"
    ],
    # A + or # value with a prefix still stops at the first "?" or "#",
    # and a label that can hold dots has to fit its prefix.
    "{#a:2}" => [
      "0 Choice 1 or 6",
      "1 Literal \"#\"",
      "2 Capture group 0 start",
      "3 CappedRun reserved, at most 2, stopping at the first \"?\" or \"#\"",
      "4 Capture group 0 end",
      "5 Jump to 7",
      "6 Jump to 7",
      "7 Done"
    ],
    "/{.a:2}/" => [
      "0 Literal \"/\"",
      "1 Choice 2 or 6",
      "2 Literal \".\"",
      "3 Capture group 0 start",
      "4 CappedRun unreserved, at most 2",
      "5 Capture group 0 end",
      "6 Literal \"/\"",
      "7 Done"
    ],
    # A name written again matches the earlier value, and the states
    # between are remembered once for each place that value took.
    "{a}/{a}" => [
      "0 Choice 1 or 6",
      "1 Capture group 0 start",
      "2 GreedyRun unreserved_or_comma, stopping at its end",
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
      "3 CappedRun unreserved, at most 1",
      "4 Capture group 0 end",
      "5 Choice 6 or 12 (once for each place of group 0)",
      "6 Literal \"/\"",
      "7 Capture group 1 start",
      "8 GreedyRun unreserved_or_comma, stopping at its end (once for " \
        "each place of group 0)",
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
    matcher.match(text)
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

  context "#capped_run" do
    def capped(length, options = {})
      build(1) do |m|
        m.capture(0) { m.capped_run(:unreserved, length, **options) }
      end
    end

    it "takes at most its length, as much as it can first" do
      matcher = build(2) do |m|
        m.capture(0) { m.capped_run(:unreserved, 2) }
        m.capture(1) { m.greedy_run(:unreserved) }
      end
      expect(captures(matcher, "abc")).to eq(["ab", "c"])
      expect(captures(matcher, "a")).to eq(["a", ""])
      expect(captures(matcher, "")).to eq(["", ""])
    end

    it "gives back what the rest needs, and takes no more than its " \
       "length for it" do
      matcher = build(1) do |m|
        m.capture(0) { m.capped_run(:unreserved, 3) }
        m.exact("b")
      end
      expect(captures(matcher, "abab")).to eq(["aba"])
      expect(captures(matcher, "ab")).to eq(["a"])
      expect(captures(matcher, "b")).to eq([""])
      expect(captures(matcher, "aaaab")).to be_nil
    end

    it "counts a character once, however it's written" do
      one = capped(1)
      ["a", "é", "%41", "%C3%A9", "%c3%a9", "%E2%82%AC",
       "%F0%9F%98%80"].each do |text|
        expect(captures(one, text)).to eq([text])
      end
      ["ab", "éa", "%41%42", "%C3%A9%C3%A9", "%C3%A9a", "a%C3%A9",
       "%E2%82%AC%41"].each do |text|
        expect(captures(one, text)).to be_nil
      end
      expect(captures(capped(2), "%E2%82%ACx")).to eq(["%E2%82%ACx"])
    end

    it "counts a triplet that isn't part of a character as one" do
      one = capped(1)
      expect(captures(one, "%FF")).to eq(["%FF"])
      expect(captures(one, "%C3")).to eq(["%C3"])
      expect(captures(one, "%A9")).to eq(["%A9"])
      ["%FF%FF", "%A9%A9", "%C3x", "%C3%41", "%C3%A9%A9"].each do |text|
        expect(captures(one, text)).to be_nil
      end
      two = capped(2)
      ["%C3x", "%E2%82x", "%A9%A9", "%C3%C3%A9"].each do |text|
        expect(captures(two, text)).to eq([text])
      end
    end

    it "can stop between the triplets of a character" do
      matcher = build(1) do |m|
        m.capture(0) { m.capped_run(:unreserved, 1) }
        m.exact("%A9")
      end
      expect(captures(matcher, "%C3%A9")).to eq(["%C3"])
    end

    it "stops at a character that isn't in its set" do
      expect(captures(capped(5), "a/b")).to be_nil
      expect(captures(capped(5), "a%4")).to be_nil
    end

    it "takes at least one character where it has to" do
      matcher = capped(2, at_least_one: true)
      expect(captures(matcher, "a")).to eq(["a"])
      expect(captures(matcher, "ab")).to eq(["ab"])
      expect(captures(matcher, "")).to be_nil
      expect(captures(matcher, "abc")).to be_nil
    end

    context "with delimiters_first" do
      let(:matcher) do
        build(2) do |m|
          m.capture(0) do
            m.capped_run(:reserved, 5, delimiters_first: true)
          end
          m.optional do
            m.exact("?")
            m.capture(1) { m.greedy_run(:reserved) }
          end
        end
      end

      it "stops at the first \"?\" or \"#\" where the rest can match" do
        expect(captures(matcher, "a?b")).to eq(["a", "b"])
        expect(captures(matcher, "a?b?c")).to eq(["a", "b?c"])
        expect(captures(matcher, "?b")).to eq(["", "b"])
      end

      it "takes as much as it can where there's none, or the rest " \
         "can't match from one" do
        expect(captures(matcher, "a/b")).to eq(["a/b", nil])
        expect(captures(matcher, "a#b")).to eq(["a#b", nil])
        strict = build(1) do |m|
          m.capture(0) do
            m.capped_run(:reserved, 5, delimiters_first: true)
          end
          m.exact("?x")
        end
        expect(captures(strict, "a?b?x")).to eq(["a?b"])
        expect(captures(strict, "a#b?x")).to eq(["a#b"])
      end

      it "doesn't reach a delimiter past its length" do
        expect(captures(matcher, "abcdef?g")).to be_nil
        expect(captures(matcher, "abcde?g")).to eq(["abcde", "g"])
      end
    end
  end

  it "#one_character takes one character of the set, however it's " \
     "written" do
    matcher = build(1) do |m|
      m.capture(0) { m.one_character(:unreserved) }
    end
    expect(captures(matcher, "a")).to eq(["a"])
    expect(captures(matcher, "%41")).to eq(["%41"])
    # A character of two, three or four bytes.
    expect(captures(matcher, "é")).to eq(["é"])
    expect(captures(matcher, "€")).to eq(["€"])
    expect(captures(matcher, "\u{1F600}")).to eq(["\u{1F600}"])
    expect(captures(matcher, "€€")).to be_nil
    expect(captures(matcher, "ab")).to be_nil
    expect(captures(matcher, "/")).to be_nil
    expect(captures(matcher, "")).to be_nil
  end

  # A run only stops where the text after it occurs, where every way on
  # from it starts with that text.
  context "a run before text it could hold" do
    it "stops only before the text, through a value that may be left " \
       "out" do
      matcher = build(1) do |m|
        left_out = []
        m.optional do
          m.capture(0) do
            m.greedy_run(:unreserved)
            left_out << m.leave_out_if_empty
          end
        end
        m.land(left_out)
        m.exact(".json")
      end
      expect(matcher.to_s).to include(
        "GreedyRun unreserved, stopping before \".json\""
      )
      expect(captures(matcher, "a.b.json")).to eq(["a.b"])
      expect(captures(matcher, "a.json.json")).to eq(["a.json"])
      expect(captures(matcher, ".json")).to eq([nil])
      expect(captures(matcher, "a.jso")).to be_nil
    end

    it "stops only before a text that has to follow it" do
      matcher = build(1) do |m|
        m.capture(0) do
          m.preferring_followed_by(["."]) { m.greedy_run(:unreserved) }
        end
        m.optional { m.exact(".x") }
      end
      expect(matcher.to_s).to include(
        "GreedyRun unreserved, stopping before \".\""
      )
      expect(captures(matcher, "a.b.x")).to eq(["a.b"])
      expect(captures(matcher, "ab")).to eq(["ab"])
    end

    it "can stop anywhere before one of several texts, or a text that " \
       "starts with a hex digit" do
      several = build(1) do |m|
        m.capture(0) do
          m.preferring_followed_by(["#", "%23"]) { m.greedy_run(:unreserved) }
        end
      end
      expect(several.to_s).not_to include("stopping before")
      hex = build(1) do |m|
        m.capture(0) do
          m.preferring_followed_by(["a"]) { m.greedy_run(:unreserved) }
        end
        m.optional { m.exact("a") }
      end
      expect(hex.to_s).not_to include("stopping before")
      # The "a"s of a pct-encoded triplet aren't places to stop.
      expect(captures(hex, "x%aa")).to eq(["x%aa"])
      expect(captures(hex, "xaa")).to eq(["xa"])
    end

    it "can stop anywhere where the ways on start differently" do
      matcher = build(1) do |m|
        left_out = []
        m.optional do
          m.capture(0) do
            m.greedy_run(:unreserved)
            left_out << m.leave_out_if_empty
          end
          m.exact("x")
        end
        m.land(left_out)
        m.exact("y")
      end
      expect(matcher.to_s).not_to include("stopping before")
      expect(captures(matcher, "axy")).to eq(["a"])
      expect(captures(matcher, "y")).to eq([nil])
    end
  end

  # Each state points past the jumps to where they lead, so a jump costs
  # the search nothing.
  it "makes no attempt at a jump" do
    {
      "{a,b}{+c}{?d*}" => ["x,y/z?k=v", "x", "", "x,y", "?k=v&j=w"],
      "{/a*}{.b}!" => ["/x/y.z!", "!", "/k=v!"]
    }.each do |pattern, uris|
      matcher = Addressable::Template::ParsedTemplate.new(pattern).matcher
      states = matcher.instance_variable_get(:@states)
      jumps = states.grep(described_class::Jump)
      expect(jumps).not_to be_empty
      uris.each do |uri|
        search = described_class::Search.new(uri)
        tried = []
        allow(search).to receive(:try).and_wrap_original do |original, *args|
          tried << args.first
          original.call(*args)
        end
        expect(matcher.match(uri, search)).not_to be_nil, "for #{uri}"
        expect(tried & jumps).to eq([])
      end
    end
  end

  it "starts past a jump the graph begins with" do
    matcher = build(1) do |m|
      to_value = m.jump_ahead
      m.optional { m.exact("skipped") }
      m.land([to_value])
      m.capture(0) { m.greedy_run(:unreserved) }
    end
    expect(captures(matcher, "abc")).to eq(["abc"])
    expect(captures(matcher, "skippedabc")).to eq(["skippedabc"])
  end

  it "#either tries the first steps, then the second" do
    matcher = build(2) do |m|
      m.either(
        lambda { m.capture(0) { m.greedy_run(:unreserved) } },
        lambda do
          m.exact("/")
          m.capture(1) { m.greedy_run(:unreserved) }
        end
      )
      m.exact("!")
    end
    expect(captures(matcher, "ab!")).to eq(["ab", nil])
    expect(captures(matcher, "/ab!")).to eq([nil, "ab"])
    expect(captures(matcher, "!")).to eq(["", nil])
    expect(captures(matcher, "/a/b!")).to be_nil
  end

  it "#as_few_as_can_be repeats its states only as far as the rest " \
     "needs" do
    matcher = build(2) do |m|
      m.capture(0) do
        m.as_few_as_can_be do
          m.one_character(:unreserved)
          m.exact("=")
        end
      end
      m.capture(1) { m.greedy_run(:unreserved_or_equals) }
    end
    expect(captures(matcher, "a=b=c")).to eq(["", "a=b=c"])
    strict = build(1) do |m|
      m.capture(0) do
        m.as_few_as_can_be do
          m.one_character(:unreserved)
          m.exact("=")
        end
      end
      m.exact("c")
    end
    expect(captures(strict, "a=b=c")).to eq(["a=b="])
    expect(captures(strict, "c")).to eq([""])
    expect(captures(strict, "a=b")).to be_nil
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

  context "#match with a block" do
    let(:matcher) do
      build(2) do |m|
        m.capture(0) { m.greedy_run(:unreserved) }
        m.capture(1) { m.greedy_run(:unreserved) }
      end
    end

    it "offers each way through in turn until the block takes one" do
      offered = []
      result = matcher.match("abc") do |texts|
        offered << texts
        texts[1] == "bc"
      end
      expect(offered).to eq([["abc", ""], ["ab", "c"], ["a", "bc"]])
      expect(result).to eq(["a", "bc"])
    end

    it "doesn't match where the block takes none" do
      offered = []
      result = matcher.match("ab") do |texts|
        offered << texts
        false
      end
      expect(offered).to eq([["ab", ""], ["a", "b"], ["", "ab"]])
      expect(result).to be_nil
    end
  end

  it "gives nil for a group nothing captured" do
    matcher = build(3) do |m|
      m.capture(1) { m.greedy_run(:unreserved) }
    end
    expect(captures(matcher, "a")).to eq([nil, "a", nil])
  end
end

describe Addressable::Template::Matcher::Units do
  sets = Addressable::Template::Matcher::SETS

  # The places a value starting at the position can end within the
  # length, as byte offsets.
  def ends(text, position, length, set = :unreserved)
    units = described_class.new(
      Addressable::Template::Matcher::SETS.fetch(set), text
    )
    before, first, last = units.reach(position, length)
    before + (first..last).map { |boundary| units.position(boundary) }
  end

  # The same, found by walking from the position a character at a time.
  def walked_ends(text, position, length, set)
    found = [position]
    count = 0
    continuing = 0
    while (after = set.character_end(text, position))
      triplet = text.getbyte(position) == 37 && after == position + 3
      octet = triplet ? text.byteslice(position + 1, 2).hex : nil
      if octet && continuing > 0 && octet >= 0x80 && octet < 0xC0
        continuing -= 1
      else
        count += 1
        continuing =
          if octet.nil? || octet < 0xC0
            0
          elsif octet >= 0xF0
            3
          elsif octet >= 0xE0
            2
          else
            1
          end
      end
      break if count > length
      found << after
      position = after
    end
    found
  end

  it "reaches a character at a time, as far as the length" do
    expect(ends("abcd", 0, 2)).to eq([0, 1, 2])
    expect(ends("abcd", 1, 9)).to eq([1, 2, 3, 4])
    expect(ends("abcd", 4, 2)).to eq([4])
    expect(ends("abcd", 2, 0)).to eq([2])
    expect(ends("", 0, 3)).to eq([0])
  end

  it "stops at a character that isn't in the set" do
    expect(ends("ab/cd", 0, 9)).to eq([0, 1, 2])
    expect(ends("ab/cd", 2, 9)).to eq([2])
    expect(ends("ab/cd", 3, 9)).to eq([3, 4, 5])
    # A "%" without two hex digits after it isn't a triplet.
    expect(ends("a%4/", 0, 9)).to eq([0, 1])
    expect(ends("a%4b", 0, 9)).to eq([0, 1, 4])
  end

  it "counts a character once, however many bytes or triplets it is" do
    expect(ends("é€\u{1F600}x", 0, 3)).to eq([0, 2, 5, 9])
    expect(ends("%C3%A9x", 0, 1)).to eq([0, 3, 6])
    expect(ends("%E2%82%ACx", 0, 1)).to eq([0, 3, 6, 9])
    expect(ends("%F0%9F%98%80x", 0, 1)).to eq([0, 3, 6, 9, 12])
    expect(ends("%41%42", 0, 1)).to eq([0, 3])
  end

  it "counts a triplet that carries no character on as one" do
    expect(ends("%A9%A9", 0, 1)).to eq([0, 3])
    expect(ends("%FF%FF", 0, 1)).to eq([0, 3])
    expect(ends("%C3x", 0, 1)).to eq([0, 3])
    # A value that starts after the triplet that began the character.
    expect(ends("%E2%82%ACx", 3, 1)).to eq([3, 6])
    expect(ends("%E2%82%ACx", 3, 2)).to eq([3, 6, 9])
    expect(ends("%E2%82%ACx", 6, 1)).to eq([6, 9])
    expect(ends("%E2%82%ACx", 3, 3)).to eq([3, 6, 9, 10])
  end

  it "reaches from inside a triplet, whose hex digits are characters " \
     "of their own there" do
    expect(ends("%41bc", 1, 2)).to eq([1, 2, 3])
    expect(ends("%41bc", 1, 3)).to eq([1, 2, 3, 4])
    expect(ends("%41bc", 2, 1)).to eq([2, 3])
    expect(ends("%41bc", 1, 0)).to eq([1])
    expect(ends("%41%C3%A9", 2, 2)).to eq([2, 3, 6, 9])
    expect(ends("%4/", 1, 5)).to eq([1, 2])
  end

  it "agrees with a walk from every position of generated text" do
    random = Random.new(6570)
    pieces = [
      "a", "é", "€", "\u{1F600}", "%41", "%C3%A9", "%E2%82%AC", "%C3",
      "%A9", "%80", "%FF", "%F0%9F", "%", "%4", "/", ",", "=", "."
    ]
    set_names = [:unreserved, :reserved, :unreserved_no_dot_or_comma]
    300.times do
      text = Array.new(random.rand(0..14)) { pieces.sample(random: random) }.join
      name = set_names.sample(random: random)
      units = described_class.new(sets.fetch(name), text)
      starts = [0]
      text.each_char { |character| starts << starts.last + character.bytesize }
      # Inside a triplet too, after its "%" and after its first digit.
      text.to_enum(:scan, /%[0-9A-F]{2}/).each do
        starts << $~.begin(0) + 1 << $~.begin(0) + 2
      end
      starts.uniq.each do |position|
        [0, 1, 2, 3, 100].each do |length|
          before, first, last = units.reach(position, length)
          found = before + (first..last).map { |b| units.position(b) }
          expect(found).to eq(
            walked_ends(text, position, length, sets.fetch(name))
          ), "for #{text.inspect} from #{position}, length #{length}, #{name}"
        end
      end
    end
  end
end

describe Addressable::Template::Matcher::Search, "#not_handed_over" do
  let(:search) { described_class.new("abcdef") }

  it "gives a state's first stretch whole" do
    expect(search.not_handed_over(:run, 3, 7)).to eq([[3, 7]])
  end

  it "gives none for a stretch with nothing in it" do
    expect(search.not_handed_over(:run, 4, 3)).to eq([])
    expect(search.not_handed_over(:run, 3, 3)).to eq([[3, 3]])
  end

  it "leaves out what the state handed over before" do
    search.not_handed_over(:run, 3, 7)
    expect(search.not_handed_over(:run, 3, 7)).to eq([])
    expect(search.not_handed_over(:run, 4, 6)).to eq([])
    expect(search.not_handed_over(:run, 1, 5)).to eq([[1, 2]])
    expect(search.not_handed_over(:run, 5, 9)).to eq([[8, 9]])
    expect(search.not_handed_over(:run, 0, 12)).to eq([[0, 0], [10, 12]])
    expect(search.not_handed_over(:run, 0, 12)).to eq([])
  end

  it "joins a stretch that only touches the one before" do
    search.not_handed_over(:run, 3, 5)
    expect(search.not_handed_over(:run, 6, 8)).to eq([[6, 8]])
    expect(search.not_handed_over(:run, 1, 2)).to eq([[1, 2]])
    expect(search.not_handed_over(:run, 1, 8)).to eq([])
  end

  it "gives a stretch apart from the one before whole, and remembers " \
     "it in its place" do
    search.not_handed_over(:run, 3, 5)
    expect(search.not_handed_over(:run, 9, 11)).to eq([[9, 11]])
    expect(search.not_handed_over(:run, 9, 11)).to eq([])
    expect(search.not_handed_over(:run, 3, 5)).to eq([[3, 5]])
  end

  it "keeps each state's stretches apart" do
    search.not_handed_over(:run, 3, 7)
    expect(search.not_handed_over(:other, 3, 7)).to eq([[3, 7]])
  end
end

describe Addressable::Template::Matcher::Memo do
  it "says a position is new the first time, and not after that" do
    memo = described_class.new(20)
    expect(memo.first_time?(0, 5)).to be(true)
    expect(memo.first_time?(0, 5)).to be(false)
    expect(memo.first_time?(0, 5)).to be(false)
  end

  it "keeps each row and each position apart" do
    memo = described_class.new(20)
    (0..20).each { |position| expect(memo.first_time?(3, position)).to be(true) }
    (0..20).each { |position| expect(memo.first_time?(1, position)).to be(true) }
    (0..20).each { |position| expect(memo.first_time?(3, position)).to be(false) }
    expect(memo.first_time?(0, 7)).to be(true)
  end

  it "takes every position from 0 to the end of the URI, and no further" do
    [0, 1, 8, 1000].each do |size|
      memo = described_class.new(size)
      expect(memo.first_time?(0, 0)).to be(true)
      expect(memo.first_time?(0, size)).to be(size != 0)
      expect(memo.first_time?(0, size)).to be(false)
      expect { memo.first_time?(0, size + 1) }.to raise_error(IndexError)
      expect(memo.positions(0)).to eq([0, size].uniq)
    end
  end

  it "lists the positions noted in a row, in order" do
    memo = described_class.new(40)
    [33, 2, 40, 8, 2, 7, 0].each { |position| memo.first_time?(1, position) }
    expect(memo.positions(1)).to eq([0, 2, 7, 8, 33, 40])
    expect(memo.positions(0)).to eq([])
    expect(memo.positions(5)).to eq([])
  end

  it "lists the rows used, each with its positions" do
    memo = described_class.new(12)
    expect(memo.to_s).to eq("")
    memo.first_time?(2, 12)
    memo.first_time?(0, 3)
    memo.first_time?(2, 0)
    expect(memo.to_s).to eq("0: 3\n2: 0 12")
  end

  it "agrees with a set of positions on generated input" do
    random = Random.new(6570)
    20.times do
      size = random.rand(0..300)
      memo = described_class.new(size)
      seen = Hash.new { |hash, row| hash[row] = {} }
      500.times do
        row = random.rand(4)
        position = random.rand(0..size)
        expect(memo.first_time?(row, position)).to be(!seen[row][position])
        seen[row][position] = true
      end
      4.times do |row|
        expect(memo.positions(row)).to eq(seen[row].keys.sort)
      end
    end
  end
end

describe Addressable::Template::Matcher::Search, "captures" do
  let(:search) { described_class.new("abcdef") }
  let(:log) { [] }

  # A state that notes its name, its position and the slots as they are
  # when the search makes its attempt.
  def probe(name)
    made = log
    state = Object.new
    state.define_singleton_method(:branches?) { false }
    state.define_singleton_method(:follow) do |search, position|
      made << [name, position, search.slots.dup]
    end
    state
  end

  it "makes the attempts in order, the last added first" do
    search.try(probe(:first), 1)
    search.try_in_order(probe(:second), 2, probe(:third), 3)
    search.try_in_order(nil, 0, probe(:fourth), 4)
    search.try_in_order(probe(:fifth), 5, nil, 0)
    expect(search.run(probe(:done))).to be(false)
    expect(log.map { |name, position, _| [name, position] }).to eq(
      [[:fifth, 5], [:fourth, 4], [:second, 2], [:third, 3], [:first, 1]]
    )
  end

  it "stops at the end state at the end of the URI" do
    done = probe(:done)
    search.try(probe(:never), 0)
    search.try(done, 6)
    search.try(done, 3)
    expect(search.run(done)).to be(true)
    expect(log).to eq([[:done, 3, []]])
  end

  it "keeps a capture for the attempts added after it" do
    search.start_capture(1, 1)
    search.end_capture(1, 3)
    done = probe(:done)
    search.try(done, 6)
    expect(search.run(done)).to be(true)
    expect(search.start_of(1)).to eq(1)
    expect(search.span(1)).to eq([1, 3])
    expect(search.captured(1)).to eq("bc")
    expect(search.captures(3)).to eq([nil, "bc", nil])
    expect(search.slots).to eq([nil, nil, 1, 3])
  end

  it "undoes a capture before an attempt added earlier is made" do
    search.try(probe(:outer), 0)
    search.start_capture(0, 1)
    search.try(probe(:inner), 2)
    search.end_capture(0, 4)
    search.start_capture(1, 4)
    search.try(probe(:innermost), 5)
    expect(search.run(probe(:done))).to be(false)
    expect(log).to eq([
      [:innermost, 5, [1, 4, 4]],
      [:inner, 2, [1, nil, nil]],
      [:outer, 0, [nil, nil, nil]]
    ])
  end

  it "undoes leaving a value out" do
    search.start_capture(0, 2)
    search.try(probe(:kept), 2)
    search.leave_out(0)
    search.try(probe(:left_out), 2)
    expect(search.run(probe(:done))).to be(false)
    expect(log).to eq([[:left_out, 2, [nil]], [:kept, 2, [2]]])
    expect(search.slots).to eq([nil])
  end

  # A value is left out before its end is noted. Were an end there all the
  # same, the group would still take no part: nothing reads an end without
  # a start.
  it "has no span or text for a group left out, whatever its end" do
    search.start_capture(0, 1)
    search.end_capture(0, 3)
    search.leave_out(0)
    expect(search.start_of(0)).to be_nil
    expect(search.span(0)).to be_nil
    expect(search.captured(0)).to be_nil
    expect(search.captures(1)).to eq([nil])
  end

  it "has no span or text for a group without both a start and an end" do
    search.start_capture(1, 1)
    expect(search.span(1)).to be_nil
    expect(search.captured(1)).to be_nil
    expect(search.span(0)).to be_nil
    expect(search.captures(2)).to eq([nil, nil])
  end

  # Every capture a failed search made has been undone by the time it
  # gives up.
  it "leaves every slot empty after a search that fails" do
    {
      "{a,b}{+c}{+d}!" => "a,b/c?d" * 20 + " !",
      "{/a*}{/b}!" => "/x/y/z" * 20 + "?!",
      "{a}/{a}!" => "xy/xz!",
      "{;a:2,b}{?c*}!" => ";a=xy;b=1?k=v&j=w" + " !"
    }.each do |pattern, text|
      matcher = Addressable::Template::ParsedTemplate.new(pattern).matcher
      failed = described_class.new(text)
      expect(matcher.match(text, failed)).to be_nil
      expect(failed.slots.compact).to eq([]), "for #{pattern}"
    end
  end
end

describe Addressable::Template::Matcher, "what a search tried" do
  matcher_class = Addressable::Template::Matcher

  def matcher(pattern)
    Addressable::Template::ParsedTemplate.new(pattern).matcher
  end

  # {/a}!, whose states that branch are 0 (the choice to leave a out) and
  # 3 (a's run), in rows 0 and 1.
  it "can be read from a search the caller gives" do
    search = matcher_class::Search.new("/xy?!")
    expect(matcher("{/a}!").match("/xy?!", search)).to be_nil
    expect(search.memo.to_s).to eq("0: 0\n1: 1")
    search = matcher_class::Search.new("/xy!")
    expect(matcher("{/a}!").match("/xy!", search)).to eq(["xy"])
    expect(search.memo.to_s).to eq("0: 0\n1: 1")
  end

  it "tries each state that branches once at each position" do
    template = matcher("{a,b}{+c}{+d}!")
    states = template.instance_variable_get(:@states).select(&:branches?)
    text = "a,b/c?d" * 30 + " !"
    search = matcher_class::Search.new(text)
    followed = Hash.new(0)
    states.each do |state|
      allow(state).to receive(:follow).and_wrap_original do |original, *args|
        followed[[state.index, args[1]]] += 1
        original.call(*args)
      end
    end
    expect(template.match(text, search)).to be_nil
    expect(followed.values.uniq).to eq([1])
    states.each do |state|
      positions = followed.keys.select { |index, _| index == state.index }
      expect(search.memo.positions(state.memo_row)).
        to eq(positions.map(&:last).sort)
    end
  end

  it "remembers a state that depends on a group by its captures too" do
    search = matcher_class::Search.new("x/y")
    expect(matcher("{a}/{a}").match("x/y", search)).to be_nil
    expect(search.instance_variable_get(:@tried_with_captures).keys).
      to eq([[8, 2, [0, 1]]])
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
