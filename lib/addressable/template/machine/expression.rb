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

        # Whether the operator writes each value after its variable's name,
        # as ;, ? and & do.
        def self.names_values?
          false
        end

        def self.tagged_value
          TaggedValue
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
        # shape expansion writes it: each variable's value may be left out,
        # the first value present comes after the leader, and each later
        # one after the joiner. Each value is as long as can be first, so
        # where two variables could take the same text, the earlier one
        # does. Each value is captured, for Matching.match_data, and a
        # value left out is captured as nothing, so it's nil. A variable that
        # can never take anything (#absorbed?) gets a group but no steps.
        #
        # This is where the machine differs from :regexp, whose regexp
        # makes the joiners optional and tries the shortest values first
        # (TEMPLATE_MACHINE_PLAN.md, "Matching fixes in the machine").
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
          groups = variables.map { matcher.new_group }
          positions = variables.each_index.reject do |position|
            absorbed?(position, patterns)
          end
          # Adds a variable's value, by its position: as its steps take it,
          # or, with :empty, nothing. With an array, a value that takes
          # nothing is left out instead, at the place the array's states are
          # later landed (Matcher#leave_out_if_empty).
          value = lambda do |position, how = nil|
            matcher.capture(groups[position]) do
              variable = variables[position]
              leaders = next_leaders.select { |text| may_hold?(variable, text) }
              names = named_texts(position, positions, patterns,
                self.class.joiner)
              if how == :empty
                # Nothing to add.
              elsif patterns[position]
                matcher.processor_pattern(patterns[position].to_s)
              elsif leaders.empty?
                variable_steps(matcher, variable, names)
              else
                # The value stops before the last place the next
                # expression's leader follows it, if the rest can match from
                # there, so that it doesn't take the next expression's
                # text: /{name}{.ext} gives "/archive.tar.gz" to name and ext
                # as "archive.tar" and "gz".
                matcher.preferring_followed_by(leaders) do
                  variable_steps(matcher, variable, names)
                end
              end
              how << matcher.leave_out_if_empty if how.is_a?(Array)
            end
          end
          # Adds the block's steps for a variable, which may be left out. An
          # exploded variable is left out first where a later variable's
          # name follows (#named_texts); prefix is the text before that
          # name.
          optional = lambda do |position, prefix, &steps|
            names = named_texts(position, positions, patterns, prefix)
            if names.empty?
              matcher.optional(&steps)
            else
              matcher.optional_unless_followed_by(names, &steps)
            end
          end
          if self.class.leader == self.class.joiner
            # Every value comes after the same text, so each one is
            # matched the same way, whether or not one came before it.
            positions.each do |position|
              optional.call(position, self.class.joiner) do
                leader_steps(matcher)
                value.call(position)
              end
            end
          else
            first_value_steps(matcher, value, positions, optional)
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

        ##
        # The steps for an expression whose leader isn't its joiner, such as
        # {?a,b} ("?" and "&") or {a,b} (nothing and ","). The leader goes
        # before whichever value comes first, so the steps come in two
        # parts. Before any value, each variable can take the leader and its
        # value, then go on to the later variables' steps in the second
        # part, or be left out. In the second part, each variable can take
        # the joiner and its value, or be left out. {?a,b,c} is:
        #
        #   (?a=… then the second part's b) or
        #   (?b=… then the second part's c) or
        #   (?c=… then the end) or nothing;
        #   second part: (&b=…)? (&c=…)?
        #
        # Each variable's steps are added twice at most, so the steps grow
        # with the number of variables.
        #
        # Without a leader (a default or + expression), an empty first value
        # writes nothing, the same as no value, unless a joiner follows it:
        # {a,b} writes ",y" for a = "" and b = "y". So there a first value
        # that takes nothing is left out (nil), unless a later value follows
        # after the joiner. A + value that stops at a "?" or "#" right away
        # (Matcher#reserved_run) is left out too: /{+base}{?q} gives "?q=1"
        # to q.
        #
        # @param [Matcher] matcher The matcher.
        # @param [Proc] value Adds a variable's value, by its position.
        # @param [Array<Integer>] positions
        #   The positions of the variables to add steps for, in order.
        # @param [Proc] optional
        #   Adds the block's steps for a variable, by its position and the
        #   text before its value, as steps that may be left out.
        def first_value_steps(matcher, value, positions, optional)
          no_leader = self.class.leader.empty?
          # The jumps into the second part, by the index in positions: to
          # each variable's steps, which may leave it out, to its joiner,
          # which it has to take, and to the end of the expression.
          ahead = Hash.new { |hash, index| hash[index] = [] }
          to_joiner = Hash.new { |hash, index| hash[index] = [] }
          positions.each_with_index do |position, index|
            left_out = []
            optional.call(position, self.class.leader) do
              leader_steps(matcher)
              value.call(position, no_leader ? left_out : nil)
              ahead[index + 1] << matcher.jump_ahead
            end
            matcher.land(left_out)
            next unless no_leader && index < positions.size - 1
            matcher.optional do
              value.call(position, :empty)
              to_joiner[index + 1] << matcher.jump_ahead
            end
          end
          # No value at all.
          ahead[positions.size] << matcher.jump_ahead
          (1...positions.size).each do |index|
            matcher.land(ahead[index])
            optional.call(positions[index], self.class.joiner) do
              matcher.land(to_joiner[index])
              matcher.exact(self.class.joiner)
              value.call(positions[index])
            end
          end
          matcher.land(ahead[positions.size])
        end

        ##
        # Whether the variable can never take anything: an exploded variable
        # right after another exploded one, which takes every member it
        # could, since the earlier variable wins. {;a*,b*} matches like
        # {;a*}. A processor's pattern can give either one other text, so a
        # variable with one, or after one, isn't absorbed.
        #
        # @param [Integer] position The variable's position.
        # @param [Array] patterns The processor's pattern for each variable.
        def absorbed?(position, patterns)
          return false if position.zero?
          before = position - 1
          variables[position].explode && variables[before].explode &&
            !patterns[position] && !patterns[before]
        end

        ##
        # The texts that start a later variable's pair, which an exploded
        # ;, ? or & value's members could also take: each later variable
        # that isn't exploded, in the expression or in the expressions right
        # after it whose leader is its joiner, after the text before it.
        # The exploded value stops before the first one where the rest can
        # match, even before its first member, so that a variable named
        # outside it takes its own pair: {?a*,b} gives "?x=1&b=2" to a and b
        # as {"x" => "1"} and "2", and "?b=2" to b.
        #
        # @param [Integer] position The exploded variable's position.
        # @param [Array<Integer>] positions The positions with steps.
        # @param [Array] patterns The processor's pattern for each variable.
        # @param [String] prefix
        #   The text before a later variable's name in the expression: the
        #   leader where it could be the first value, the joiner otherwise.
        #
        # @return [Array<String>] The texts.
        def named_texts(position, positions, patterns, prefix)
          return [] unless self.class.names_values?
          return [] unless variables[position].explode
          later = positions.select do |after|
            after > position && !variables[after].explode && !patterns[after]
          end
          texts = later.map { |after| prefix + variables[after].name }
          node = following
          while node.is_a?(Expression) && node.class.names_values? &&
              node.class.leader == self.class.joiner
            node.variables.each do |variable|
              texts << node.class.leader + variable.name unless variable.explode
            end
            node = node.following
          end
          texts
        end

        # The texts the next expression's leader can be written as, or none
        # if the next node isn't an expression with a leader.
        def next_leaders
          return [] unless following.is_a?(Expression)
          leader = following.class.leader
          return [] if leader.empty?
          leader == "#" && following.fragment ? ["#", "%23"] : [leader]
        end

        # Whether the variable's value can hold the text, so that it could
        # take the next expression's leader: in its characters, or as the
        # joiner between an exploded value's members. A "%23" is a
        # pct-encoded triplet, which every value can hold.
        def may_hold?(variable, text)
          return true if text == "%23"
          return true if variable.explode && text == self.class.joiner
          return !is_a?(OpLabel) || label_dots if text == "."
          self.class.allows_reserved?
        end

        # The leader, a "#" in either form where a fragment may have
        # started before it.
        def leader_steps(matcher)
          leader = self.class.leader
          if leader == "#" && fragment
            matcher.literal([["#", "%23"]])
          elsif !leader.empty?
            matcher.exact(leader)
          end
        end

        # A variable's value: exploded, with the joiner between its members,
        # or as its operator takes a value. An exploded value stops before
        # the first of the names (#named_texts) where the rest can match. A
        # + or # value before the last stops at the next comma, which
        # expansion writes between values; only the last can hold one.
        def variable_steps(matcher, variable, names = [])
          if variable.explode && !names.empty?
            matcher.repeat_stopping_before(self.class.joiner, names) do
              member_steps(matcher)
            end
          elsif variable.explode
            matcher.repeat(self.class.joiner) do
              member_steps(matcher)
            end
          elsif self.class.allows_reserved? && !variable.equal?(variables.last)
            matcher.reserved_run(:reserved_no_comma)
          else
            value_steps(matcher, variable)
          end
        end

        # A value: unreserved characters, as many as can be first. The ;, ?
        # and & operators write the variable's name first, so they need it;
        # an exploded value's member, which has no variable, reuses this
        # for the others.
        def value_steps(matcher, _variable = nil)
          matcher.greedy_run(:unreserved)
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
