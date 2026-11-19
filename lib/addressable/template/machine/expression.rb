# frozen_string_literal: true

#--
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
#++

require "addressable/template/machine/tagged_value"

module Addressable
  class Template
    module Machine
      # An expression: its variables, and what every operator shares. It's
      # the base class of the operators, and is never built itself; its
      # defaults are simple expansion's, which OpPlain keeps. Each
      # operator's subclass declares its operator, leader and joiner with
      # class methods, and overrides the instance methods for the shapes of
      # its values. Its methods come in three parts: expansion, matching
      # (the steps it adds to a Matcher) and the regexp (its part of
      # Template#to_regexp, as :regexp writes it).
      class Expression
        def self.operator; ""; end
        def self.leader; ""; end
        def self.joiner; ","; end

        def self.allows_reserved?
          false
        end

        def self.tagged_value
          TaggedValue
        end

        # Whether an exploded value's members need the joiner between them.
        def self.joiner_required?
          false
        end

        # The operator for the rest of the expression once partial_expand
        # has written a value: {?a,b} with only a given becomes ?a=1{&b},
        # and {#a,b} becomes #1{+b}.
        def self.partial_continuation
          self
        end

        # A lookbehind for the regexp: not right after a character a value
        # can hold (unreserved or non-ASCII). A value that starts here
        # can't take the end of a run of such characters from the value
        # before it. "{+a}{b}" matches "p/qr" with a = "p/" and b = "qr":
        # a can't stop at "p/q", since b would then start right after "q".
        NOT_AFTER_VALUE =
          "(?<![#{Addressable::URI::CharacterClasses::UNRESERVED}])" \
          "(?<![^\\x00-\\x7F])".freeze

        attr_reader :variables

        # What matching the expression depends on around it, set by Parser.

        # Whether a fragment may have started before the expression, so that
        # expansion encoded its "#" leader as "%23".
        attr_accessor :fragment
        # Whether a {.var} expression's value can contain "."
        # (Matching.label_takes_dots?). Only ever true for one unexploded
        # variable, so never for an exploded value's members.
        attr_accessor :label_dots
        # The node right after the expression: a Literal, another
        # expression, or nil at the end of the pattern.
        attr_reader :following

        def initialize(variables)
          @variables = variables
          # Parser sets these for a valid pattern.
          @fragment = false
          @label_dots = false
          @following = nil
          @comma_may_start_here = false
        end

        ##
        # Notes the node right after the expression, and whether the text
        # from the expression on could start with a comma: its own match,
        # or, since it can match nothing, whatever follows it. Parser calls
        # it going back from the end of the pattern, so the node after it
        # already knows.
        #
        # @param [Literal, Expression, nil] following
        #   The node after the expression, or nil at the end.
        def place_before(following)
          @following = following
          @comma_may_start_here = may_start_with_comma? || comma_follows?
        end

        # The expression as the pattern writes it.
        def pattern_text
          "{#{self.class.operator}#{variables.map(&:pattern_text).join(',')}}"
        end

        # --- Expansion ---

        ##
        # The expression's expansion: its defined variables' values, joined
        # with its leader and separator.
        #
        # @param [Values] values The expansion's values.
        #
        # @return [String] The expansion, or "" if no variable is defined.
        def expand(values)
          list = variables.map do |variable|
            values.expand(variable)
          end
          list.compact!
          list.empty? ? "" : joined_values(list)
        end

        ##
        # The expression's text in a partially expanded pattern. An
        # expression whose variables are all given is expanded, and one
        # with none given is kept. Otherwise its given variables are
        # expanded and its missing ones kept, in runs. A variable that's
        # given but undefined (nil, or a list or associative array with no
        # defined members) is dropped, so that it doesn't split the missing
        # variables around it.
        #
        # @param [Values] values The expansion's values.
        #
        # @return [String] The expression's new text.
        def partial_expand(values)
          given = lambda { |variable| values.key?(variable.name) }
          is_defined = lambda do |variable|
            values.defined_value?(variable.name)
          end
          return expand(values) if variables.all?(&given)
          return pattern_text if variables.none?(&given)

          vars = partial_order(is_defined).select do |variable|
            !given.call(variable) || is_defined.call(variable)
          end
          # Consecutive variables that are all given, or all missing, stay
          # in one expression, so that their separator is kept. Every given
          # run has a value, since undefined variables were dropped.
          partial_runs(values, vars.chunk(&given).to_a)
        end

        def joined_values(list)
          self.class.leader + list.flat_map(&:parts).join(self.class.joiner)
        end

        # --- Matching ---

        ##
        # Adds the steps that match the expression to the matcher, in the
        # order of :regexp's reference regexp (template_match_spec.rb):
        # nothing first, then the leader and each variable's value, which
        # may be left out, with an optional joiner between them. Each value
        # is captured, for Matching.match_data.
        #
        # @param [Matcher] matcher The matcher.
        # @param [#match, nil] processor
        #   A processor whose match method may give a variable's value a
        #   pattern of its own, which then has to match.
        def add_match_steps(matcher, processor = nil)
          # Asked for every variable before any steps, as :regexp asks.
          patterns = variables.map do |variable|
            processor && processor.match(variable.name)
          end
          leader = self.class.leader
          matcher.nothing_or do
            if leader == "#" && fragment
              matcher.literal([["#", "%23"]])
            elsif !leader.empty?
              matcher.exact(leader)
            end
            variables.each_with_index do |variable, position|
              if position > 0
                matcher.optional { matcher.exact(self.class.joiner) }
              end
              if patterns[position]
                matcher.capture do
                  matcher.processor_pattern(patterns[position].to_s)
                end
              else
                matcher.optional do
                  matcher.capture do
                    variable_steps(matcher, variable)
                  end
                end
              end
            end
          end
        end

        # --- Regexp ---

        ##
        # The expression's part of Template#to_regexp, as :regexp writes it:
        # nothing, or the leader and each variable's value, which may be
        # left out, with an optional joiner between them. Each value is a
        # group named after its variable (Matching.capture_name).
        #
        # @return [String] The regular expression source.
        def regexp_source
          leader = self.class.leader
          leader =
            if leader == "#" && fragment
              NUMBER_SIGN_EITHER_FORM
            else
              Regexp.escape(leader)
            end
          if following && following.absorbs?(self)
            # Each expression tried its empty alternative first. When the
            # next one can match anything this one could, followed by
            # anything it could match on its own, every other choice ends
            # where the empty one can also end, so the empty alternative
            # always gave the first match.
            "(?:|(?!)#{leader}#{joined_groups_regexp_source})"
          else
            "(?:|#{leader}#{values_regexp_source})"
          end
        end

        # Whether this expression, right after the other one, can match
        # anything the other could, followed by anything it could match on
        # its own. Only a default or + expression can.
        def absorbs?(_previous)
          false
        end

        # Whether this expression could match a string that starts with a
        # comma. Only a default or + expression, which has no leader, can.
        def may_start_with_comma?
          false
        end

        # Whether the text from the expression on could start with a comma.
        # Set by #place_before.
        def comma_may_start_here?
          @comma_may_start_here
        end

        # Whether the text after the expression could start with a comma.
        def comma_follows?
          following ? following.comma_may_start_here? : false
        end

        # Whether the expression is one variable that isn't exploded.
        def single_value?
          variables.size == 1 && !variables.first.explode
        end

        private

        # A variable is the last one if its varspec is the same as the last
        # varspec, so {+a,a} has no variable before the last.
        def last?(variable)
          variable.pattern_text == variables.last.pattern_text
        end

        # --- Expansion ---

        # The variables in the order partial_expand writes them: as the
        # pattern writes them. A query overrides it.
        def partial_order(_is_defined)
          variables
        end

        ##
        # Writes the runs of a partially expanded expression: each given run
        # expanded and each missing one kept, as an expression of their own.
        # Once a value is written, the rest continue with the
        # partial_continuation operator. The comma operators override it.
        #
        # @param [Values] values The expansion's values.
        # @param [Array<Array>] runs
        #   Each run of given or missing variables, as [given, variables].
        #
        # @return [String] The runs' text.
        def partial_runs(values, runs)
          operator = self.class
          runs.each_with_object(String.new) do |(is_given, run), acc|
            if is_given
              acc << operator.new(run).expand(values)
              operator = operator.partial_continuation
            else
              acc << operator.new(run).pattern_text
            end
          end
        end

        # The runs of a simple, reserved or fragment expression, whose
        # values are separated by commas. A missing variable keeps its
        # separator only if it ends up undefined. Once a value is written, a
        # fragment's "#" is certain, so it comes first, and every run
        # continues without it.
        def partial_comma_runs(values, runs)
          leader = self.class.leader
          leading = !leader.empty? && runs.any? { |is_given, _| is_given }
          started = false
          result = leading ? String.new(leader) : String.new
          runs.each_with_object(result) do |(is_given, run), acc|
            operator =
              if started || leading
                self.class.partial_continuation
              else
                self.class
              end
            if is_given
              # Even an empty string takes a separator.
              acc << "," if started
              started = true
              acc << operator.new(run).expand(values)
            else
              acc << operator.new(run).pattern_text
            end
          end
        end

        # --- Matching ---

        # A variable's value: exploded, up to the next comma, or as its
        # operator takes a value.
        def variable_steps(matcher, variable)
          if variable.explode
            matcher.repeat(self.class.joiner, self.class.joiner_required?) do
              member_steps(matcher)
            end
          elsif self.class.allows_reserved? && !last?(variable)
            # A + or # variable before the last takes its value up to the
            # next comma.
            matcher.possessive_run(:reserved_no_comma)
          else
            value_steps(matcher)
          end
        end

        # A value: unreserved characters, as few as can be first.
        def value_steps(matcher)
          matcher.lazy_run(:unreserved)
        end

        # An exploded value's member.
        def member_steps(matcher)
          value_steps(matcher)
        end

        # --- Regexp ---

        # The variables' groups, as :regexp writes them for what follows the
        # expression. A + or # expression writes them differently before
        # text that can't start with a comma.
        def values_regexp_source
          joined_groups_regexp_source
        end

        # Each variable's group, with an optional joiner between them.
        def joined_groups_regexp_source
          groups = variables.each_with_index.map do |variable, position|
            group_regexp_source(variable, position)
          end
          groups.join("#{joiner_regexp_source}?")
        end

        ##
        # A variable's group in the regexp, as :regexp writes it for a
        # default, / or . expression. The other operators override it.
        #
        # @param [Variable] variable The variable.
        # @param [Integer] position
        #   The variable's position in the expression.
        #
        # @return [String] The regular expression source.
        def group_regexp_source(variable, position)
          if variable.explode && exploded_after?(position)
            # Exploded values were tried shortest first, and a later
            # exploded variable can match whatever this one leaves, so once
            # a split fails, every split where this variable is longer fails
            # too. Of the values tried, only the leading joiners are shorter
            # than every value tried before them.
            named_group_regexp_source(
              variable, "(?:#{joiner_regexp_source})*"
            )
          elsif !variable.explode && position < variables.size - 1
            # Values were tried shortest first, so a run of characters
            # without a joiner went to a later variable. The only other
            # value that could change the result is the whole run up to the
            # next joiner.
            value = value_regexp_source
            joiner = joiner_regexp_source
            named_group_regexp_source(variable, "(?:#{value}(?=#{joiner}))??")
          else
            optional_group_regexp_source(variable)
          end
        end

        # A group for the variable's value, left out when the value is.
        def optional_group_regexp_source(variable)
          value = variable_regexp_source(variable)
          "#{named_group_regexp_source(variable, value)}?"
        end

        # A group named after the variable (Matching.capture_name).
        def named_group_regexp_source(variable, source)
          "(?<#{Matching.capture_name(variable.name)}>#{source})"
        end

        # A variable's value: exploded, or as its operator takes a value.
        def variable_regexp_source(variable)
          if variable.explode
            member = member_regexp_source
            "#{member}(?:#{joiner_regexp_source}#{member})*"
          else
            value_regexp_source
          end
        end

        # The joiner, escaped for a regular expression.
        def joiner_regexp_source
          Regexp.escape(self.class.joiner)
        end

        # Whether a variable before the position is exploded.
        def exploded_before?(position)
          variables.first(position).any?(&:explode)
        end

        # Whether a variable after the position is exploded.
        def exploded_after?(position)
          variables.drop(position + 1).any?(&:explode)
        end

        # A value: unreserved characters, as few as can be first.
        def value_regexp_source
          "#{UNRESERVED}*?"
        end

        # An exploded value's member.
        def member_regexp_source
          value_regexp_source
        end
      end
    end
  end
end
