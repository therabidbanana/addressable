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
        # does. Each value is captured, for #read, and a value left out is
        # captured as nothing, so it's nil.
        #
        # This is where the machine differs from :regexp, whose regexp
        # makes the joiners optional and tries the shortest values first
        # (TEMPLATE_MACHINE_PLAN.md, "Matching rules").
        #
        # What a varspec's steps depend on in the varspecs before it is
        # already decided, in its slot (Slots): one that can never take
        # anything gets a group but no steps, one that can never take a
        # character gets none for a value, one whose name an earlier
        # varspec has matches only that one's value (RepeatedValue), and
        # one with a processor's pattern has to match it.
        #
        # @param [Matcher] matcher The matcher.
        # @param [Array<Slot>] slots The expression's slots, in order.
        def add_match_steps(matcher, slots)
          slots = slots.reject(&:absorbed)
          if self.class.leader == self.class.joiner
            # Every value comes after the same text, so each one is
            # matched the same way, whether or not one came before it.
            slots.each do |slot|
              optional_steps(matcher, slot, slots, self.class.joiner) do
                leader_steps(matcher)
                captured_steps(matcher, slot, slots)
              end
            end
          else
            first_value_steps(matcher, slots)
          end
        end

        ##
        # The value a match gives a variable, from the text its group
        # captured, before it's decoded, and the name it goes under.
        # Every value came after its leader or joiner, so an exploded
        # value's empty text is one empty member.
        #
        # A ;, ? or & value is captured with its name. Outside an exploded
        # value the name is the text before the first "=", which is the
        # variable's unless a processor's pattern matched other text; the
        # value is what follows, up to the next "=". An exploded one's
        # members are a list if every name is the variable's, as an
        # exploded list repeats it, and an associative array otherwise,
        # where an empty member is a "" key.
        #
        # A value that isn't exploded and holds a comma as it is, is a
        # list, where the variable can hold one (#holds_list?). A default,
        # / or . value that's exploded, whose members each hold an "=" as
        # it is, is an associative array (#members_can_be_pairs?).
        #
        # @param [Variable] variable The variable.
        # @param [String, nil] text
        #   The text captured, or nil if the variable took no part.
        # @param [TrueClass, FalseClass] as_matched
        #   Whether the text was matched by the variable's own steps, not
        #   a processor's pattern, whose text is given as it is.
        #
        # @return [Array, nil]
        #   The name, and a String, Array, Hash or nil; or nil if no value
        #   writes the text.
        def read(variable, text, as_matched = true)
          name, value = read_text(variable, text)
          if !as_matched
            # A processor's pattern matched the text.
          elsif value.is_a?(String) && holds_list?(variable) &&
              value.include?(",")
            value = value.split(",", -1)
          elsif value.is_a?(Array) && members_can_be_pairs? &&
              value.all? { |member| member.include?("=") }
            # The steps take members that are all pairs, or none.
            pairs = value.map { |member| member.split("=", 2) }
            keys = pairs.map do |key, _|
              Addressable::URI.unencode_component(key)
            end
            # An associative array has each key once, so no value writes
            # the same key twice.
            return nil unless keys.uniq.size == keys.size
            value = Hash[pairs]
          end
          [name, value]
        end

        # The name and value #read gives, before a list is told from a
        # string.
        def read_text(variable, text)
          name = variable.name
          return [name, nil] if text.nil?
          if variable.explode
            members = text.split(self.class.joiner, -1)
            members = [""] if members.empty?
            return [name, members] unless self.class.names_values?
            pairs = members.map do |pair|
              key, member = pair.split("=", 2)
              [key.to_s, member || ""]
            end
            if pairs.all? { |key, _| key == name }
              [name, pairs.map { |_, member| member }]
            else
              [name, Hash[pairs]]
            end
          elsif self.class.names_values?
            written_name, value = text.split("=")
            [written_name, value || ""]
          else
            [name, text]
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

        # The set of characters a variable's value can hold as it is, as
        # its steps match it (Matcher::SETS). A + or # value before the
        # last can't hold a comma.
        def value_set(variable)
          if self.class.allows_reserved?
            variable.equal?(variables.last) ? :reserved : :reserved_no_comma
          elsif holds_list?(variable)
            :unreserved_or_comma
          else
            :unreserved
          end
        end

        ##
        # Whether a variable's value can be a list written with commas
        # between its members, as expansion writes a list or an
        # associative array in a variable that isn't exploded: {/a} writes
        # ["x", "y"] as "/x,y". Outside + and #, a comma in a string is
        # written "%2C", so a comma as it is can only be between members.
        # Where the operator's joiner is the comma too ({a,b}), only the
        # last variable can: a comma after an earlier one is the joiner,
        # as it is for + and #. Not with a prefix, which expansion refuses
        # for a list. An exploded value's member, which has no variable,
        # never is.
        #
        # @param [Variable, nil] variable The variable, or nil for a member.
        def holds_list?(variable)
          return false if variable.nil? || variable.explode || variable.prefix
          return false if self.class.allows_reserved?
          self.class.joiner != "," || variable.equal?(variables.last)
        end

        ##
        # Whether a variable's value, once it starts, can only end at the
        # end of its run of characters: whatever can follow it starts with
        # a character it can't hold, or ends the template. That's the joiner
        # (a later variable in the expression can follow; no value holds
        # its joiner), and what follows the expression (#starts_outside?).
        # Only for an unexploded value that isn't + or #: those stop at a
        # "?" or "#" in their run.
        #
        # @param [Variable] variable The variable.
        #
        # @return [TrueClass, FalseClass]
        def end_decided?(variable)
          return false if variable.explode || self.class.allows_reserved?
          starts_outside?(following, Matcher::SETS.fetch(value_set(variable)))
        end

        ##
        # Whether an exploded value's members can be an associative
        # array's pairs, each written as its key, "=" and its value: a
        # default, / or . expression's, where {/a*} writes {"k" => "v"} as
        # "/k=v". There an "=" inside a key, a value or a list's member is
        # written "%3D", so an "=" as it is can only be a pair's. A ;, ?
        # or & member always has its name and "=" (#member_steps). A + or
        # # member holds "=" as it is, so a pair can't be told from a
        # list's member, and it's a list's.
        def members_can_be_pairs?
          !self.class.allows_reserved? && !self.class.names_values?
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
        # Adds a slot's value, captured in its group: as its steps take it,
        # or, with :empty, nothing. With an array, a value that takes
        # nothing is left out instead, at the place the array's states are
        # later landed (Matcher#leave_out_if_empty).
        #
        # @param [Matcher] matcher The matcher.
        # @param [Slot] slot The slot.
        # @param [Array<Slot>] slots The expression's slots with steps.
        # @param [Symbol, Array, nil] how :empty, an array, or nil.
        def captured_steps(matcher, slot, slots, how = nil)
          repeated = slot.repeated
          extends = repeated && repeated.extends?
          matcher.capture(slot.group) do
            variable = slot.variable
            leaders = next_leaders.select { |text| may_hold?(variable, text) }
            if repeated && !extends
              matcher.same_value(repeated.first_group, repeated)
            elsif how == :empty
              # Nothing to add.
            elsif slot.pattern
              matcher.processor_pattern(slot.pattern.to_s)
            elsif leaders.empty?
              variable_steps(matcher, variable,
                named_texts(slot, slots, self.class.joiner))
            else
              # The value stops before the last place the next
              # expression's leader follows it, if the rest can match from
              # there, so that it doesn't take the next expression's
              # text: /{name}{.ext} gives "/archive.tar.gz" to name and ext
              # as "archive.tar" and "gz".
              matcher.preferring_followed_by(leaders) do
                variable_steps(matcher, variable,
                  named_texts(slot, slots, self.class.joiner))
              end
            end
            # A value of its own that has to agree with an earlier one
            # is checked even when it's empty, so it isn't left out.
            if how.is_a?(Array) && !extends
              how << matcher.leave_out_if_empty
            end
          end
          if extends
            matcher.starts_with(repeated.first_group, slot.group, repeated)
          end
        end

        ##
        # Adds the block's steps for a slot, which may be left out. An
        # exploded variable is left out first where a later variable's name
        # follows (#named_texts). A name written again is left out only
        # where its first varspec allows it (RepeatedValue#left_out?).
        #
        # @param [Matcher] matcher The matcher.
        # @param [Slot] slot The slot.
        # @param [Array<Slot>] slots The expression's slots with steps.
        # @param [String] prefix
        #   The text before a later variable's name: the leader where it
        #   could be the first value, the joiner otherwise.
        def optional_steps(matcher, slot, slots, prefix, &steps)
          names = named_texts(slot, slots, prefix)
          repeated = slot.repeated
          if repeated
            matcher.optional_same_value(repeated.first_group, repeated, &steps)
          elsif names.empty?
            matcher.optional(&steps)
          else
            matcher.optional_unless_followed_by(names, &steps)
          end
        end

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
        # @param [Array<Slot>] slots The expression's slots with steps.
        def first_value_steps(matcher, slots)
          no_leader = self.class.leader.empty?
          # The jumps into the second part, by the index in slots: to each
          # variable's steps, which may leave it out, to its joiner, which
          # it has to take, and to the end of the expression.
          ahead = Hash.new { |hash, index| hash[index] = [] }
          to_joiner = Hash.new { |hash, index| hash[index] = [] }
          slots.each_with_index do |slot, index|
            # A slot that can never take a character has no steps for a
            # value, only those for an empty one before a joiner.
            unless slot.empty_only
              left_out = []
              optional_steps(matcher, slot, slots, self.class.leader) do
                leader_steps(matcher)
                captured_steps(matcher, slot, slots,
                  no_leader ? left_out : nil)
                ahead[index + 1] << matcher.jump_ahead
              end
              matcher.land(left_out)
            end
            next unless no_leader && index < slots.size - 1
            matcher.optional do
              captured_steps(matcher, slot, slots, :empty)
              to_joiner[index + 1] << matcher.jump_ahead
            end
          end
          # No value at all.
          ahead[slots.size] << matcher.jump_ahead
          (1...slots.size).each do |index|
            matcher.land(ahead[index])
            optional_steps(matcher, slots[index], slots, self.class.joiner) do
              matcher.land(to_joiner[index])
              matcher.exact(self.class.joiner)
              captured_steps(matcher, slots[index], slots)
            end
          end
          matcher.land(ahead[slots.size])
        end

        ##
        # Whether the text from the node on starts with a character outside
        # the set, or is the end of the template. An expression may match
        # nothing, so its leader and what follows it both have to. A
        # literal or leader written "#" that may be "%23", one that starts
        # with "%", and a default or + expression, which has no leader, can
        # all start with what the set holds.
        #
        # @param [Literal, Expression, nil] node The node.
        # @param [Matcher::CharacterSet] set The set.
        #
        # @return [TrueClass, FalseClass]
        def starts_outside?(node, set)
          return true if node.nil?
          text = node.is_a?(Literal) ? node.pattern_text : node.class.leader
          return false if text.empty? || text.start_with?("%")
          return false if text.start_with?("#") && node.fragment
          return false if set.holds?(text[0])
          node.is_a?(Literal) || starts_outside?(node.following, set)
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
        # @param [Slot] slot The exploded variable's slot.
        # @param [Array<Slot>] slots The expression's slots with steps.
        # @param [String] prefix
        #   The text before a later variable's name in the expression: the
        #   leader where it could be the first value, the joiner otherwise.
        #
        # @return [Array<String>] The texts.
        def named_texts(slot, slots, prefix)
          return [] unless self.class.names_values?
          return [] unless slot.variable.explode
          later = slots.select do |after|
            after.group > slot.group && !after.variable.explode &&
              !after.pattern
          end
          texts = later.map { |after| prefix + after.variable.name }
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
        # the first of the names (#named_texts) where the rest can match.
        def variable_steps(matcher, variable, names = [])
          if variable.explode && !names.empty?
            matcher.repeat_stopping_before(self.class.joiner, names) do
              member_steps(matcher)
            end
          elsif variable.explode && members_can_be_pairs?
            # Members that are all values, or else all pairs: a list, or
            # an associative array.
            matcher.either(
              lambda do
                matcher.repeat(self.class.joiner) { member_steps(matcher) }
              end,
              lambda do
                matcher.repeat(self.class.joiner) do
                  member_steps(matcher)
                  matcher.exact("=")
                  member_steps(matcher)
                end
              end
            )
          elsif variable.explode
            matcher.repeat(self.class.joiner) do
              member_steps(matcher)
            end
          else
            value_steps(matcher, variable)
          end
        end

        # A value: unreserved characters, as many as can be first. The ;, ?
        # and & operators write the variable's name first, so they need it;
        # an exploded value's member, which has no variable, reuses this
        # for the others.
        def value_steps(matcher, variable = nil)
          value_run(matcher, variable, value_set(variable))
        end

        # A run of a set's characters for a value, as many as can be first:
        # at most its prefix's length, for a variable with one.
        def value_run(matcher, variable, set)
          if variable && variable.prefix
            matcher.capped_run(set, variable.prefix)
          else
            matcher.greedy_run(set)
          end
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
