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

require "timeout"
require "addressable/template"

module TemplateMatchSpec
  OPERATORS = [nil, "+", "#", "/", ".", ";", "?", "&"]

  # A direct version of Template#parse_new_template_pattern, without the
  # changes that keep matching from backtracking catastrophically. It's the
  # reference for the order in which a match tries its choices.
  REFERENCE_PARSE_NEW_TEMPLATE_PATTERN = <<-'RUBY'
    def parse_new_template_pattern(pattern, processor = nil)
      # Escape the pattern. The two gsubs restore the escaped curly braces
      # back to their original form. Basically, escape everything that isn't
      # within an expansion.
      escaped_pattern = Regexp.escape(
        pattern
      ).gsub(/\\\{(.*?)\\\}/) do |escaped|
        escaped.gsub(/\\(.)/, "\\1")
      end

      expansions = []

      # Create a regular expression that captures the values of the
      # variables in the URI.
      regexp_string = escaped_pattern.gsub( EXPRESSION ) do |expansion|

        expansions << expansion
        _, operator, varlist = *expansion.match(EXPRESSION)
        leader = Regexp.escape(LEADERS.fetch(operator, ''))
        joiner = Regexp.escape(JOINERS.fetch(operator, ','))
        varspecs = varlist.split(',')
        combined = varspecs.map do |varspec|
          _, name, modifier = *varspec.match(VARSPEC)

          result = processor && processor.respond_to?(:match) ? processor.match(name) : nil
          if result
            "(?<#{name}>#{ result })"
          else
            group = case operator
            when '+'
              "#{ RESERVED }*?"
            when '#'
              "#{ RESERVED }*?"
            when '/'
              "#{ UNRESERVED }*?"
            when '.'
              "#{ UNRESERVED.gsub('\.', '') }*?"
            when ';'
              "#{ UNRESERVED }*=?#{ UNRESERVED }*?"
            when '?'
              "#{ UNRESERVED }*=#{ UNRESERVED }*?"
            when '&'
              "#{ UNRESERVED }*=#{ UNRESERVED }*?"
            else
              "#{ UNRESERVED }*?"
            end
            if modifier == '*'
              seg = case operator
                    when '+', '#' then "#{RESERVED_NO_COMMA}*+"
                    else group
                    end
              joiner_pattern = operator.nil? ? joiner : "#{joiner}?"
              "(?<#{name}>#{seg}(?:#{joiner_pattern}#{seg})*)?"
            elsif varspecs.size > 1 && (operator == '+' || operator == '#') &&
                  varspec != varspecs.last
              "(?<#{name}>#{RESERVED_NO_COMMA}*+)?"
            else
              "(?<#{name}>#{group})?"
            end
          end
        end.join("#{joiner}?")
        "(?:|#{leader}#{combined})"
      end

      # Ensure that the regular expression matches the whole URI.
      regexp_string = "\\A#{regexp_string}\\z"
      return expansions, Regexp.new(regexp_string)
    end
  RUBY

  module Reference
    %w[
      EXPRESSION VARSPEC LEADERS JOINERS RESERVED RESERVED_NO_COMMA UNRESERVED
    ].each do |name|
      const_set(name, Addressable::Template.const_get(name))
    end

    module_eval(REFERENCE_PARSE_NEW_TEMPLATE_PATTERN)
    extend self
  end

  def self.reference_regexp(pattern)
    Reference.parse_new_template_pattern(pattern)[1]
  end

  def self.regexp(pattern)
    Addressable::Template.new(pattern).send(:parse_template_pattern, pattern)[1]
  end

  # Whether expanding the mapping writes the string, with pct-encoded
  # triplets decoded on both sides: a match decodes its values, and
  # expansion may encode them differently from the string.
  def self.expands_to?(template, mapping, string)
    expanded = template.expand(mapping).to_s
    Addressable::URI.unencode(expanded) == Addressable::URI.unencode(string)
  rescue TypeError
    # A mapping with a nil key, which :regexp gives for an empty capture
    # with no name, doesn't expand.
    false
  end

  # Whether the string has two ;, ? or & pairs with the same name, where
  # the pattern has an exploded ;, ? or & value. A hash can't hold both,
  # so such a string can't expand back from a match (the plan's "repeated
  # names in an exploded ;, ? or & value").
  def self.repeats_a_name?(pattern, string)
    return false unless pattern =~ /\{[;?&][^}]*\*/
    # Leave out the literal text the pattern ends with.
    string = string.chomp(pattern[/\}([^}]*)\z/, 1])
    names = string.split(/[;?&]/, -1).drop(1).map do |pair|
      pair.split("=", 2).first.to_s
    end
    names.uniq.size < names.size
  end

  # Expects the :machine engine's #match to be sound for each string,
  # where :regexp can't be its oracle, since the machine fixes some of its
  # results (TEMPLATE_MACHINE_PLAN.md, "Matching fixes in the machine"):
  # every match the machine gives expands back to the string, and every
  # string :regexp matches with a mapping that expands back to it, the
  # machine matches too.
  def self.expect_sound_matches(example, pattern, strings)
    machine = Addressable::Template.new(pattern, engine: :machine)
    regexp = Addressable::Template.new(pattern, engine: :regexp)
    strings.each do |string|
      next if repeats_a_name?(pattern, string)
      actual = machine.match(string)
      if actual
        example.expect(expands_to?(machine, actual.mapping, string)).to(
          example.be(true),
          "#{actual.mapping.inspect} doesn't expand to #{string.inspect}"
        )
      else
        expected = regexp.match(string)
        example.expect(
          expected && expands_to?(regexp, expected.mapping, string)
        ).to example.be_falsey, "doesn't match #{string.inspect}"
      end
    end
  end

  # The :machine engine's results where they differ from the :regexp
  # engine's in "when a URI can be split between variables more than one
  # way" (TEMPLATE_MACHINE_PLAN.md, "Matching fixes in the machine"). Each
  # expands back to its URI, except where noted.
  MACHINE_SPLITS = {
    # An empty member is a "" key, which expansion writes as an empty
    # member, not nil.
    ["{;a*}", ";a;;b"] => {"a" => {"a" => "", "" => "", "b" => ""}},
    # A value stops before the last place the next expression's leader
    # follows it, if the rest can match.
    ["{/a*}{/b}", "/x/y/z"] => {"a" => ["x", "y"], "b" => "z"},
    ["{.a*}{.b}", ".x.y.z"] => {"a" => ["x", "y"], "b" => "z"},
    ["{&a*}{&b}", "&x=1=2&b=3"] => {"a" => {"x" => "1=2"}, "b" => "3"},
    # The earlier variable takes what both could take, in one expression or
    # across two, and a variable the URI leaves out is nil.
    ["{a*}{b}", "x,y,z"] => {"a" => ["x", "y", "z"], "b" => nil},
    ["{a*,b}", "x,y,z"] => {"a" => ["x", "y", "z"], "b" => nil},
    ["{+d*,a}?", ";,,x?"] => {"d" => [";", "", "x"], "a" => nil},
    ["{\#a*,d*,b}=", "\#,,="] => {"a" => ["", "", ""], "d" => nil, "b" => nil},
    ["{a*,b,c}", "x,y,z"] => {"a" => ["x", "y", "z"], "b" => nil, "c" => nil},
    ["{/a,b,c}", "/x"] => {"a" => "x", "b" => nil, "c" => nil},
    ["{/a,b,c}", "/x/y"] => {"a" => "x", "b" => "y", "c" => nil},
    ["{.a,b}.json", ".x.json"] => {"a" => "x", "b" => nil},
    ["{a,b,c}", "x,y"] => {"a" => "x", "b" => "y", "c" => nil},
    ["{/a,b*}", "/x/y"] => {"a" => "x", "b" => ["y"]},
    ["{;a,b}", ";a=1"] => {"a" => "1", "b" => nil},
    ["{;a,b*}x", ";ax"] => {"a" => "", "b" => nil},
    ["{+a*,b*}", "x,y"] => {"a" => ["x", "y"], "b" => nil},
    ["{+a*,b*,c}", "x,y,z"] => {"a" => ["x", "y", "z"], "b" => nil, "c" => nil},
    ["{+a*,b,c*}", "x,y"] => {"a" => ["x", "y"], "b" => nil, "c" => nil},
    ["{+a*,b}z", "x,yz"] => {"a" => ["x", "y"], "b" => nil},
    ["{\#a*,c*,b,b}/-", "\#k=a;b,n=a,a=b,a=b/-"] => {
      "a" => ["k=a;b", "n=a", "a=b", "a=b"], "c" => nil, "b" => nil
    },
    ["{;a*,b*}", ";a=1;b=2"] => {"a" => {"a" => "1", "b" => "2"}, "b" => nil},
    ["{/a*,b*}", "/x/y"] => {"a" => ["x", "y"], "b" => nil},
    ["{/a*,b*}", "//x/y"] => {"a" => ["", "x", "y"], "b" => nil},
    ["{/a*,b,c*}", "/x/y/z"] => {
      "a" => ["x", "y", "z"], "b" => nil, "c" => nil
    },
    ["{a*,b*}", ",x,y"] => {"a" => ["", "x", "y"], "b" => nil},
    ["{+a}{+b}{+c}", "xyz"] => {"a" => "xyz", "b" => nil, "c" => nil},
    ["{+a}{+b}{+c}", "x,y/z"] => {"a" => "x,y/z", "b" => nil, "c" => nil},
    ["{+a}{+b}x", "pqx"] => {"a" => "pq", "b" => nil},
    ["{a}{b}{c}", "xyz"] => {"a" => "xyz", "b" => nil, "c" => nil},
    ["{.a,b}{c}", ".x.yz"] => {"a" => "x", "b" => "yz", "c" => nil},
    ["{/a}{+b}", "/x/y"] => {"a" => "x", "b" => "/y"},
    ["{a}{+b}{c}{+d}", "w/x"] => {
      "a" => "w", "b" => "/x", "c" => nil, "d" => nil
    },
    ["{+a,b}{+c,d}", "x,y,z"] => {
      "a" => "x", "b" => "y,z", "c" => nil, "d" => nil
    },
    ["{\#a,b}{+c,d}", "\#x,y"] => {
      "a" => "x", "b" => "y", "c" => nil, "d" => nil
    },
    # The comma before z can only be c's: b's value can't hold one. So c
    # starts with an empty member, as expanding ["", "z"] writes it.
    ["{a,b}{c*}", "x,y,z"] => {"a" => "x", "b" => ["y", "z"], "c" => nil},
    # A . value that isn't exploded holds a list's commas, and the earlier
    # variable wins.
    ["{.a}{c*}", ".x,y"] => {"a" => ["x", "y"], "c" => nil},
    ["{a*}{c,d*}", "x,y"] => {"a" => ["x", "y"], "c" => nil, "d" => nil},
    ["{+a}{b}", "p/q"] => {"a" => "p/q", "b" => nil},
    ["{+a}{b}", "p/qr"] => {"a" => "p/qr", "b" => nil},
    ["{\#a}{b}", "\#p/q"] => {"a" => "p/q", "b" => nil},
    # A + or # value before the last stops at a comma.
    ["{+v1,v2,v3}", "a"] => {"v1" => "a", "v2" => nil, "v3" => nil},
    ["{+v1,v2,v3}", "a,b"] => {"v1" => "a", "v2" => "b", "v3" => nil},
    ["{+v1,v2,v3}x", "a,bx"] => {"v1" => "a", "v2" => "b", "v3" => nil},
    # A name written again has one value, so these don't match: v1 would
    # be "a" and "c", and the first a* takes every member, which leaves
    # the others none.
    ["{+v1,v2,v1}", "a,b,c"] => nil,
    ["{?a*,a*,a*}", "?a=aba=ab&a=ab"] => nil,
    ["{;b*,c*}", ";n=ak=ab;c=a2Cb"] => {
      "b" => {"n" => "ak=ab", "c" => "a2Cb"}, "c" => nil
    },
    # A variable a ;, ? or & expression names outside an exploded one
    # takes its own pair.
    ["{?a*,b*,c}", "?a=1&b=2&c=3"] => {
      "a" => {"a" => "1", "b" => "2"}, "b" => nil, "c" => "3"
    },
    # No expansion writes "?&" or "&&", so these don't match.
    ["{?a*,b*}", "?&b=2"] => nil,
    ["{&a*,b*}", "&&b=2"] => nil,
    ["{?a*,b,c*}", "?&=="] => nil
  }.freeze

  # Expressions placed after a single expression, so that a different order
  # of end positions picks a different split.
  CONTEXTS = ["", "x", "{b}", "{+b}"]

  # The expression without the \A and \z anchors around the whole template.
  def self.unanchored(regexp)
    regexp.source[/\A\\A(.*)\\z\z/m, 1]
  end

  def self.leader(operator)
    Addressable::Template::LEADERS.fetch(operator, "")
  end

  def self.joiner(operator)
    Addressable::Template::JOINERS.fetch(operator, ",")
  end

  # Every position at which the expression can stop matching a prefix of the
  # string, in the order that the regular expression engine tries them. Two
  # expressions that give the same order behave the same way wherever they
  # appear in a template.
  def self.end_positions(expression, string)
    remaining = (0..string.size).to_a
    order = []
    until remaining.empty?
      stops = remaining.map { |index| "(?=.{#{string.size - index}}\\z)" }
      match = Regexp.new(
        "\\A#{expression}(?:#{stops.join("|")})", Regexp::MULTILINE
      ).match(string)
      break unless match
      order << match[0].size
      remaining.delete(match[0].size)
    end
    order
  end

  # The named captures of a match, or nil. MatchData#named_captures needs
  # Ruby 2.4. With duplicate names, match[name] gives the last group with
  # that name that matched, as named_captures does.
  def self.named_captures(match)
    match && Hash[match.names.map { |name| [name, match[name]] }]
  end

  # Every string of up to max_length tokens drawn from alphabet.
  def self.strings(alphabet, max_length)
    (0..max_length).flat_map do |length|
      alphabet.repeated_permutation(length).map(&:join)
    end.uniq
  end

  def self.alphabet(operator, *extra)
    ([leader(operator), joiner(operator), "a", "=", "%41"] + extra).
      reject(&:empty?).uniq
  end
end

describe Addressable::Template, "#match" do
  context "when a URI can be split between variables more than one way" do
    {
      ["{;a*}", ";a;;b"] => {"a" => {"a" => "", nil => "", "b" => ""}},
      ["{/a*}{/b}", "/x/y/z"] => {"a" => ["x", "y", "z"], "b" => nil},
      ["{.a*}{.b}", ".x.y.z"] => {"a" => ["x", "y", "z"], "b" => nil},
      # A member can be empty, but a joiner before a later variable in the
      # same expression isn't one.
      ["{a*}{b}", "x,y,z"] => {"a" => ["x", "y", ""], "b" => "z"},
      ["{a*,b}", "x,y,z"] => {"a" => ["x", "y"], "b" => "z"},
      ["{a*}", "x,,y,"] => {"a" => ["x", "", "y", ""]},
      ["{/a*}", "/x/"] => {"a" => ["x", ""]},
      ["{/segments*}", "/a/b/"] => {"segments" => ["a", "b", ""]},
      ["{/segments*}", "/"] => {"segments" => [""]},
      ["{/segments*}", ""] => {"segments" => nil},
      ["{+d*,a}?", ";,,x?"] => {"d" => [";", ""], "a" => "x"},
      ["{\#a*,d*,b}=", "\#,,="] => {"a" => ["", ""], "d" => nil, "b" => ""},
      ["{a*,b,c}", "x,y,z"] => {"a" => ["x"], "b" => "y", "c" => "z"},
      # With several variables, a value without a joiner goes to the last
      # variable for /, . and the default operator...
      ["{/a,b,c}", "/x"] => {"a" => "", "b" => "", "c" => "x"},
      ["{/a,b,c}", "/x/y"] => {"a" => "", "b" => "x", "c" => "y"},
      ["{.a,b}.json", ".x.json"] => {"a" => "", "b" => "x"},
      ["{a,b,c}", "x,y"] => {"a" => "", "b" => "x", "c" => "y"},
      ["{/a,b*}", "/x/y"] => {"a" => "", "b" => ["x", "y"]},
      # ...and to the first variable for ;.
      ["{;a,b}", ";a=1"] => {"a" => "", "b" => nil, "1" => ""},
      ["{;a,b}", ";a=1;b=2"] => {"a" => "1", "b" => "2"},
      ["{;a,b*}x", ";ax"] => {"a" => "", "b" => {}},
      # With several exploded variables, the first one takes the values for
      # +, # and ;...
      ["{+a*,b*}", "x,y"] => {"a" => ["x", "y"], "b" => []},
      ["{+a*,b*,c}", "x,y,z"] => {"a" => ["x", "y", "z"], "b" => [], "c" => ""},
      ["{+a*,b,c*}", "x,y"] => {"a" => ["x", "y"], "b" => "", "c" => []},
      ["{+a*,b}z", "x,yz"] => {"a" => ["x"], "b" => "y"},
      ["{#a*,c*,b,b}/-", "#k=a;b,n=a,a=b,a=b/-"] => {
        "a" => ["k=a;b", "n=a", "a=b"], "c" => nil, "b" => ""
      },
      ["{;a*,b*}", ";a=1;b=2"] => {"a" => {"a" => "1", "b" => "2"}, "b" => {}},
      # ...and for ? and &, unless an empty member comes first...
      ["{?a*,b*}", "?a=1&b=2"] => {"a" => {"a" => "1", "b" => "2"}, "b" => nil},
      ["{?a*,b*,c}", "?a=1&b=2&c=3"] => {
        "a" => {"a" => "1", "b" => "2", "c" => "3"}, "b" => nil, "c" => nil
      },
      # ...and the last one for /, . and the default operator.
      ["{/a*,b*}", "/x/y"] => {"a" => [], "b" => ["x", "y"]},
      ["{/a*,b*}", "//x/y"] => {"a" => [""], "b" => ["x", "y"]},
      ["{/a*,b,c*}", "/x/y/z"] => {
        "a" => [], "b" => "", "c" => ["x", "y", "z"]
      },
      ["{a*,b*}", ",x,y"] => {"a" => [""], "b" => ["x", "y"]},
      # An expression directly followed by one that can match anything it
      # could is empty.
      ["{+a}{+b}{+c}", "xyz"] => {"a" => nil, "b" => nil, "c" => "xyz"},
      ["{+a}{+b}{+c}", "x,y/z"] => {"a" => nil, "b" => nil, "c" => "x,y/z"},
      ["{+a}{+b}x", "pqx"] => {"a" => nil, "b" => "pq"},
      ["{a}{b}{c}", "xyz"] => {"a" => nil, "b" => nil, "c" => "xyz"},
      ["{.a,b}{c}", ".x.yz"] => {"a" => nil, "b" => nil, "c" => ".x.yz"},
      ["{/a}{+b}", "/x/y"] => {"a" => nil, "b" => "/x/y"},
      ["{a}{+b}{c}{+d}", "w/x"] => {
        "a" => nil, "b" => nil, "c" => nil, "d" => "w/x"
      },
      ["{+a,b}{+c,d}", "x,y,z"] => {
        "a" => nil, "b" => nil, "c" => "x", "d" => "y,z"
      },
      ["{#a,b}{+c,d}", "#x,y"] => {
        "a" => nil, "b" => nil, "c" => "#x", "d" => "y"
      },
      ["{a,b}{c*}", "x,y,z"] => {
        "a" => nil, "b" => nil, "c" => ["x", "y", "z"]
      },
      ["{.a}{c*}", ".x,y"] => {"a" => nil, "c" => [".x", "y"]},
      ["{a*}{c,d*}", "x,y"] => {"a" => nil, "c" => "", "d" => ["x", "y"]},
      # An exploded {+b*} only ends where a run of characters ends.
      ["{+a}{+b*}x", "p,qx"] => {"a" => "p,q", "b" => nil},
      # {b} can't match "/", so {+a} isn't always empty.
      ["{+a}{b}", "p/q"] => {"a" => "p/", "b" => "q"},
      ["{+a}{b}", "p/qr"] => {"a" => "p/", "b" => "qr"},
      ["{#a}{b}", "#p/q"] => {"a" => "p/", "b" => "q"},
      # In + and # expressions, the earlier variables take one value each.
      ["{+v1,v2,v3}", "a"] => {"v1" => "a", "v2" => "", "v3" => ""},
      ["{+v1,v2,v3}", "a,b"] => {"v1" => "a", "v2" => "b", "v3" => ""},
      ["{+v1,v2,v3}", "a,b,c,d"] => {
        "v1" => "a", "v2" => "b", "v3" => "c,d"
      },
      ["{+v1,v2,v3}x", "a,bx"] => {"v1" => "a", "v2" => nil, "v3" => "b"},
      ["{+v1,v2,v3}x", "a,b,x"] => {"v1" => "a", "v2" => "b", "v3" => ""},
      ["{#v1,v2}", "#,b"] => {"v1" => "", "v2" => "b"},
      ["{+v1,v2},x", "a,b,x"] => {"v1" => "a", "v2" => "b"},
      ["{+v1,v2,v1}", "a,b,c"] => {"v1" => "", "v2" => "a"},
      # An exploded ;, ? or & value keeps everything after its first "=",
      # and pairs that all repeat the variable's name are a list.
      ["{;b*}", ";b==a"] => {"b" => ["=a"]},
      ["{;a*}", ";a=b=c;d"] => {"a" => {"a" => "b=c", "d" => ""}},
      ["{&b*}", "&k=ab%3Bb="] => {"b" => {"k" => "ab;b="}},
      ["{?a*}", "?a=b=c&d=e"] => {"a" => {"a" => "b=c", "d" => "e"}},
      ["{?a*}", "?a=bc=d"] => {"a" => ["bc=d"]},
      ["{;b*,c*}", ";n=ak=ab;c=a2Cb"] => {
        "b" => {"n" => "ak=ab", "c" => "a2Cb"}, "c" => {}
      },
      ["{?a*,a*,a*}", "?a=aba=ab&a=ab"] => {"a" => ["aba=ab", "ab"]},
      ["{?a*,c*}", "?a=b=c&d=e"] => {
        "a" => {"a" => "b=c", "d" => "e"}, "c" => nil
      },
      ["{&a*}{&b}", "&x=1=2&b=3"] => {
        "a" => {"x" => "1=2", "b" => "3"}, "b" => nil
      },
      ["{;a*}{?b*}", ";a=1;b?c=d=e"] => {
        "a" => {"a" => "1", "b" => ""}, "b" => {"c" => "d=e"}
      },
      # For ? and &, an empty member before the first exploded variable's
      # values gives them to the next one.
      ["{?a*,b*}", "?&b=2"] => {"a" => nil, "b" => ["2"]},
      ["{&a*,b*}", "&&b=2"] => {"a" => nil, "b" => ["2"]},
      ["{?a*,b,c*}", "?&=="] => {
        "a" => nil, "b" => nil, nil => "", "c" => {"" => ""}
      }
    }.each do |(pattern, uri), mapping|
      it "matches #{uri.inspect} against #{pattern}" do
        expect(
          Addressable::Template.new(pattern, engine: :regexp).match(uri).mapping
        ).to eq(mapping)
      end

      machine_mapping =
        TemplateMatchSpec::MACHINE_SPLITS.fetch([pattern, uri], mapping)
      it "matches #{uri.inspect} against #{pattern} with the :machine engine" do
        match = Addressable::Template.new(pattern, engine: :machine).match(uri)
        expect(match && match.mapping).to eq(machine_mapping)
      end
    end

    # The reference regexp is the oracle for how the :regexp engine splits
    # a URI, and these examples pin its builder to it. The :machine engine
    # fixes some of those splits, so in machine mode the examples after
    # them check only that its matches are sound (expect_sound_matches).
    TemplateMatchSpec::OPERATORS.product(["", "*"]).each do |operator, modifier|
      pattern = "{#{operator}a#{modifier}}"
      # A lone label variable at the end of a template takes every character
      # up to the end, so it's compared where it doesn't end the template.
      pattern += "a" if operator == "." && modifier == ""
      it "tries the reference's end positions in its order for #{pattern}" do
        reference = TemplateMatchSpec.unanchored(
          TemplateMatchSpec.reference_regexp(pattern)
        )
        current = TemplateMatchSpec.unanchored(
          TemplateMatchSpec.regexp(pattern)
        )
        alphabet = TemplateMatchSpec.alphabet(operator)
        TemplateMatchSpec.strings(alphabet, 5).each do |string|
          expect(TemplateMatchSpec.end_positions(current, string)).to eq(
            TemplateMatchSpec.end_positions(reference, string)
          ), "for #{string.inspect}"
        end
      end
    end

    TemplateMatchSpec::OPERATORS.each do |operator|
      [
        "{#{operator}a,b,c}", "{#{operator}a,b*}", "{#{operator}a*,b}",
        "{#{operator}a,b}x", "{#{operator}a,b}{#{operator}c}",
        "{#{operator}a*,b*}", "{#{operator}a*,b*,c*}", "{#{operator}a*,b,c*}",
        "{#{operator}a,b*,c*}", "{#{operator}a*,b*,c}",
        "{#{operator}a*,c*,b,b}", "{#{operator}a*,b}x", "{#{operator}a*,b*}x",
        "{#{operator}a*,b,c}x",
        "{#{operator}a}{+b}", "{#{operator}a,b*}{+c}", "{#{operator}a}{b}",
        "{#{operator}a*}{b}{+c}", "{#{operator}a}{+b}x",
        "{#{operator}a,b,c}x", "{#{operator}a,b},x", "{#{operator}a,b,a}",
        "{#{operator}a,b:2,c}/", "{#{operator}a,b}{+c,d}",
        "{#{operator}a}{c*}", "{#{operator}a,b}{c,d*}", "{#{operator}a}{+c*}x",
        "{#{operator}a,b}{c,d}"
      ].each do |pattern|
        it "captures the same values as the reference for #{pattern}" do
          reference = TemplateMatchSpec.reference_regexp(pattern)
          current = TemplateMatchSpec.regexp(pattern)
          alphabet = TemplateMatchSpec.alphabet(operator, "x")
          TemplateMatchSpec.strings(alphabet, 5).each do |string|
            expected = reference.match(string)
            actual = current.match(string)
            expect(TemplateMatchSpec.named_captures(actual)).to eq(
              TemplateMatchSpec.named_captures(expected)
            ), "for #{string.inspect}"
          end
        end

        # Only in machine mode, to keep the default run quick. A pattern
        # that writes a name twice is checked too: the machine only
        # matches where the name's values agree.
        if TestHelper.template_engine == :machine
          it "matches soundly for #{pattern}" do
            alphabet = TemplateMatchSpec.alphabet(operator, "x")
            TemplateMatchSpec.expect_sound_matches(
              self, pattern, TemplateMatchSpec.strings(alphabet, 5)
            )
          end
        end
      end
    end

    if TestHelper.template_engine == :machine
      TemplateMatchSpec::OPERATORS.product(
        ["", "*"], TemplateMatchSpec::CONTEXTS
      ).each do |operator, modifier, context|
        pattern = "{#{operator}a#{modifier}}#{context}"
        it "matches soundly for #{pattern}" do
          alphabet = TemplateMatchSpec.alphabet(operator, "x")
          TemplateMatchSpec.expect_sound_matches(
            self, pattern, TemplateMatchSpec.strings(alphabet, 5)
          )
        end
      end
    end

    # Not a contract worth keeping, but a change to it belongs in a minor
    # release (see TEMPLATE_MACHINE_PLAN.md, "Template bugs").
    it "raises NoMethodError for nil" do
      expect { Addressable::Template.new("{a}").match(nil) }.
        to raise_error(NoMethodError)
    end

    it "calls a processor's match method once per variable, in order" do
      processor = Object.new
      names = []
      processor.define_singleton_method(:match) do |name|
        names << name
        nil
      end
      Addressable::Template.new("{/a,b}{;c}").match("/x/y;c=1", processor)
      expect(names).to eq(["a", "b", "c"])
    end

    it "gives the later of adjacent expressions the value with a processor" do
      processor = Object.new
      def processor.match(name)
        nil
      end
      template = Addressable::Template.new("{+a}{+b}", engine: :regexp)
      expect(template.match("xy", processor).mapping).to eq(
        "a" => nil, "b" => "xy"
      )
    end

    it "gives the earlier of adjacent expressions the value with a processor " \
      "with the :machine engine" do
      processor = Object.new
      def processor.match(name)
        nil
      end
      template = Addressable::Template.new("{+a}{+b}", engine: :machine)
      expect(template.match("xy", processor).mapping).to eq(
        "a" => "xy", "b" => nil
      )
    end

    it "matches the other variables around a processor's pattern" do
      processor = Object.new
      def processor.match(name)
        name == "b" ? "[0-9]+" : nil
      end
      template = Addressable::Template.new("{/a,b,c}", engine: :regexp)
      expect(template.match("/x/1/y", processor).mapping).to eq(
        "a" => "x", "b" => "1", "c" => "y"
      )
      expect(template.match("/x1", processor).mapping).to eq(
        "a" => "x", "b" => "1", "c" => ""
      )
    end

    # A variable with a pattern is optional like any other, so the earlier
    # variable takes text the pattern could match.
    it "matches the other variables around a processor's pattern with the " \
      ":machine engine" do
      processor = Object.new
      def processor.match(name)
        name == "b" ? "[0-9]+" : nil
      end
      template = Addressable::Template.new("{/a,b,c}", engine: :machine)
      expect(template.match("/x/1/y", processor).mapping).to eq(
        "a" => "x", "b" => "1", "c" => "y"
      )
      expect(template.match("/x1", processor).mapping).to eq(
        "a" => "x1", "b" => nil, "c" => nil
      )
    end
  end

  context "with adversarial input" do
    {
      "{/foo*}" => "/" + ("%41/" * 1000) + "!",
      "{/foo*}{?q*}" => "/" + ("a/" * 500) + "?" + ("a=" * 500) + "!",
      "{/foo*,bar}" => "/" + ("a/" * 1000) + "!",
      "{/foo*}.json" => "/" + ("a/" * 1000) + ".jso",
      "{/foo*} (empty members)" => ("/" * 2000) + "!",
      "{.foo*} (empty members)" => ("." * 2000) + "!",
      "x{.foo*}{;bar*}" => "x." + ("a." * 500) + ";" + ("a=" * 500) + "!",
      "{foo*} (empty members)" => ("," * 2000) + "!",
      "{;foo*}" => ";" + ("a=" * 1000) + "!",
      "{;foo*} (percent-encoded)" => ";" + ("%41=" * 1000) + "!",
      "{;foo*} (empty members)" => (";" * 2000) + "!",
      "{;foo*} (equals signs)" => ";" + ("=" * 2000) + "!",
      "{;foo*,bar}" => ";" + ("a=" * 1000) + "!",
      "{?foo*}" => "?" + ("a=" * 1000) + "!",
      "{?foo*} (percent-encoded)" => "?" + ("%41=" * 1000) + "!",
      "{?foo*} (equals signs)" => "?" + ("=" * 2000) + "!",
      "{?foo*,bar}" => "?" + ("a=" * 1000) + "!",
      "{&foo*}" => "&" + ("a=" * 1000) + "!",
      "{/foo,bar,baz}" => "/" + ("a" * 2000) + "!",
      "{/a,b,c,d,e}" => "/" + ("a" * 1000) + "!",
      "{/foo,bar}{/baz,qux}" => "/" + ("a" * 2000) + "!",
      "http://example.com/repos{/owner,repo,ref}" =>
        "http://example.com/repos/" + ("a" * 2048) + "!",
      "{.foo,bar,baz}" => "." + ("a" * 2000) + "!",
      "{foo,bar,baz}" => ("a" * 2000) + "!",
      "{foo,bar,baz} (percent-encoded)" => ("%41" * 1000) + "!",
      "{;foo}" => ";" + ("a" * 8000) + "!",
      "{;foo,bar,baz}" => ";" + ("a" * 8000) + "!",
      "{;foo,bar,baz} (values)" => ";" + ("a=" * 1000) + "!",
      "{;foo,bar*,baz}" => ";" + ("a" * 4000) + "!",
      "{?foo,bar,baz}" => "?" + ("a=" * 1000) + "!",
      "{&foo,bar,baz}" => "&" + ("a=" * 1000) + "!",
      "{+foo*,bar*}" => ("a," * 5000) + " ",
      "{+foo*,bar*,baz*}" => ("a," * 2000) + " ",
      "{#foo*,bar*,baz*}" => "#" + ("a," * 2000) + " ",
      "{+foo*,bar*,baz}" => ("a," * 2000) + " ",
      "{+foo*,bar,baz*}" => ("a," * 2000) + " ",
      "{;foo*,bar*,baz*}" => ";" + ("a=1;" * 2000) + "!",
      "{/foo*,bar*,baz*}" => "/" + ("a/" * 2000) + "!",
      "{/foo*,bar,baz*}" => "/" + ("a/" * 2000) + "!",
      "{.foo*,bar*}" => "." + ("a." * 2000) + "!",
      "{foo*,bar*,baz*}" => ("a," * 2000) + "!",
      "{?foo*,bar*}" => "?" + ("a=1&" * 2000) + " ",
      "{?foo*,bar*,baz*}" => "?" + ("a=1&" * 2000) + " ",
      "{&foo*,bar*,baz*}" => "&" + ("a=1&" * 2000) + " ",
      "{?foo*,bar*,baz}" => "?" + ("a=1&" * 2000) + " ",
      "{?foo,bar*,baz*}" => "?" + ("a=1&" * 2000) + " ",
      "{?foo*,bar*} (empty members)" => "?" + ("a=&&" * 2000) + " ",
      "{+a}{+b}{+c}" => ("a" * 4000) + " ",
      "{a}{b}{c}" => ("a" * 4000) + "!",
      "{.a,b}{c}" => "." + ("a" * 4000) + "!",
      "{/a}{+b}" => "/" + ("a" * 4000) + " ",
      "{a}{+b}{c}{+d}" => ("a" * 4000) + " ",
      "{+a}{b}" => ("a/" * 4000) + " ",
      "{#a}{b}" => "#" + ("a/" * 4000) + " ",
      "{+v1,v2,v3,v4,v5,v6,v7,v8,v9,v10}" => ("a," * 4000) + " ",
      "{+v1,v2,v3,v4,v5,v6,v7,v8,v9,v10}x" => ("a," * 4000) + " ",
      "{#v1,v2,v3,v4,v5,v6,v7,v8}" => "#" + ("," * 8000) + " ",
      "{+v1,v2,v3,v4,v5,v6,v7,v8}{+c,d}" => ("a," * 2000) + " ",
      "{a,b}{c*}" => ("a," * 2000) + "!",
      "{.a,b}{c,d*}" => "." + ("a" * 4000) + "!"
    }.each do |name, payload|
      it "rejects a long payload for #{name} in linear time" do
        template = Addressable::Template.new(name.split(" ").first)
        expect do
          Timeout.timeout(10) do
            expect(template.match(payload)).to be_nil
          end
        end.not_to raise_error
      end
    end
  end
end
