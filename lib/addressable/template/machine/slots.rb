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

require "addressable/template/matching"
require "addressable/template/machine/expression"
require "addressable/template/machine/repeated_value"

module Addressable
  class Template
    module Machine
      ##
      # One varspec's place in a match: its expression, its variable, the
      # group that captures its value, the processor's pattern for it (or
      # nil), and how it matches, which depends on the varspecs before it:
      #
      # - absorbed: it can never take anything, so it gets no steps, and
      #   its value is always nil.
      # - empty_only: it can never take a character, so it gets no steps
      #   for a value, and is nil, or "" where a joiner follows it.
      # - repeated: a RepeatedValue if it matches only an earlier varspec's
      #   value, and otherwise nil.
      #
      # A slot with none of them matches a value of its own.
      #
      # @api private
      Slot = Struct.new(:expression, :variable, :group, :pattern, :absorbed,
        :empty_only, :repeated)

      ##
      # A template's slots: one for each varspec, in order, worked out
      # before any of the matcher's states are added, so that each
      # expression adds its steps from what's already decided
      # (Expression#add_match_steps). Once the matcher has split a URI
      # between the groups, the slots turn what each captured into the
      # match's mapping (#mapping).
      #
      # A varspec is absorbed if it's an exploded variable right after
      # another exploded one in its expression, which takes every member it
      # could, since the earlier variable wins. {;a*,b*} matches like
      # {;a*}. A processor's pattern can give either one other text, so a
      # variable with one, or after one, isn't absorbed. Nor is one whose
      # members can be a list's values or an associative array's pairs
      # (Expression#members_can_be_pairs?): the earlier variable takes
      # all of one kind, and the later can take the other, so {/a*,b*}
      # gives "/x/k=v" a ["x"] and b {"k" => "v"}.
      #
      # A varspec is empty_only if it's the first of a default expression
      # ({b} or {b,c}) right after a default or + expression, with no
      # literal between. Neither expression has a leader, so wherever b
      # could take a character, a variable of the expression before could
      # have taken it, and the earlier variable wins: {a}{b} gives "xy" to
      # a, and b is nil. In {a}{b,c}, "xy,z" gives b "", for its joiner.
      # It isn't for an exploded b, which can start with its own joiner,
      # nor a + one, which takes what the value before it leaves at a "?"
      # or "#". Nor where the expression before can't take everything:
      # where one of its varspecs has a prefix, a processor's pattern or a
      # RepeatedValue, or b has a pattern. It still counts as a value
      # between two varspecs with the same name, as it did when it had
      # steps.
      #
      # A varspec that repeats an earlier one's name becomes a
      # RepeatedValue, which matches only the earlier value, where that
      # value's place in the URI is decided:
      #
      # - Where it starts and ends: it and every variable before it end at
      #   the end of their runs of characters, since what follows each is a
      #   character it can't hold (Expression#end_decided?).
      # - What comes between: no variable with a value of its own between
      #   the two, only literals and other RepeatedValues, whose values the
      #   earlier ones decide.
      #
      # Then the earlier value can only be in a few places, and the search
      # stays linear, though it remembers states between the two once for
      # each place it took (Matcher#note_dependencies). /{lang}/docs{?lang},
      # {.who,who} and {a}/{a} qualify. {a}{b}{a} and {a}{a} don't: the
      # earlier a could end anywhere, and checking each place costs the
      # value's length, so the search would grow with the square of the
      # URI's. They match as if the name were written once, the first value
      # given winning. Only varspecs that aren't exploded and have no
      # processor pattern count.
      #
      # An earlier varspec with a prefix has only the start of the value,
      # so a later one without matches a value of its own, which has to
      # start with the earlier one's (RepeatedValue#extends?). Two with
      # prefixes match as if the name were written once.
      #
      # @api private
      class Slots
        NONE = [].freeze

        # How many slots the template has: one for each varspec.
        attr_reader :size

        ##
        # @param [Array] nodes The template's nodes, all valid.
        # @param [#match, nil] processor
        #   A processor whose match method may give a variable's value a
        #   pattern of its own. It's asked for every varspec, in order,
        #   before any steps are added, as :regexp asks.
        def initialize(nodes, processor = nil)
          @size = 0
          # The first slot with each name whose value's place is decided,
          # and how many values of their own came up to it.
          @firsts = {}
          @values_up_to = {}
          # How many slots with values of their own so far.
          @values = 0
          # Whether the next value's start is decided.
          @start_decided = true
          @by_expression = {}.compare_by_identity
          # The expression before, and its slots.
          before = nil
          nodes.grep(Expression).each do |expression|
            before = nil unless before && before.following.equal?(expression)
            previous = nil
            slots = expression.variables.map do |variable|
              pattern = processor && processor.match(variable.name)
              previous = add(expression, variable, pattern, previous)
            end
            if before && takes_all_before?(slots.first, @by_expression[before])
              slots.first.empty_only = true
            end
            @by_expression[expression] = slots
            before = expression
          end
          @all = @by_expression.values.flatten.freeze
          # The slots of each name written more than once, to check that
          # their values agree (#mapping). A processor's pattern can give
          # a slot any text, so a name with one isn't checked.
          @written_again = @all.group_by { |slot| slot.variable.name }.values.
            select { |slots| slots.size > 1 && slots.none?(&:pattern) }.freeze
        end

        # The node's slots, in order. A literal has none.
        def of(node)
          @by_expression.fetch(node, NONE)
        end

        ##
        # Reads each slot's value from what its group captured
        # (Expression#read), for one way of splitting the URI, if that way
        # can be a match.
        #
        # Expansion writes one value everywhere a name is, so a split
        # where a name's varspecs took values that disagree (#agree?)
        # isn't one: {a}.{a} doesn't match "x.y". Where the search could
        # compare them as it went, it already has (RepeatedValue). This
        # checks the rest. ParsedTemplate#match asks the search for
        # another split when this turns one down, but the search can't
        # reach every split, so a URI can go unmatched though some split
        # of it agrees: {a}{a} doesn't match "xx", since nothing gives
        # the second a a value.
        #
        # @param [Array<String, nil>] texts
        #   The text each group captured, or nil if it took no part.
        #
        # @return [Array<Array>, nil]
        #   Each slot's name and value, in order, for #mapping; or nil if
        #   a name's values disagree.
        def read(texts)
          values = @all.map do |slot|
            slot.expression.read(slot.variable, texts[slot.group],
              slot.pattern.nil?)
          end
          # A slot whose text no value writes (Expression#read).
          return nil if values.include?(nil)
          values if @written_again.all? { |slots| agree?(slots, values) }
        end

        ##
        # The mapping a match gives: each name with its value, restored
        # (Matching.restore). Every varspec's name is in it, even without
        # a value.
        #
        # A name written again keeps its first value, unless that was nil.
        # A value replaces one that's less of it: a whole value replaces a
        # prefix's, which is only its start, and a longer prefix's
        # replaces a shorter one's. {/var:1,var} gives "/v/value" var
        # "value", and {a:1}{a:2} gives "xxy" a "xy".
        #
        # @param [Array<Array>] values Each slot's name and value (#read).
        # @param [#restore, nil] processor The processor, if any.
        #
        # @return [Hash] The mapping.
        def mapping(values, processor = nil)
          mapping = {}
          # How much of each name's value its value so far is: a prefix's
          # length, or everything.
          widths = {}
          @all.each do |slot|
            variable = slot.variable
            mapping[variable.name] ||= nil
            name, value = values[slot.group]
            value = Matching.restore(name, value, processor)
            width = variable.prefix || Float::INFINITY
            if mapping[name].nil? || (!value.nil? && width > widths[name])
              mapping[name] = value
              widths[name] = width
            end
          end
          mapping
        end

        private

        ##
        # Whether one value could have written what each of a name's slots
        # took. They're compared decoded, each with the widest: a whole
        # value if a slot has one, and otherwise the longest prefix.
        #
        # @param [Array<Slot>] slots The slots with the name.
        # @param [Array<Array>] read
        #   The name and value read for each of the template's slots.
        def agree?(slots, read)
          values = slots.map { |slot| Matching.decode(read[slot.group].last) }
          widest = slots.each_index.reject { |index| values[index].nil? }.
            max_by { |index| slots[index].variable.prefix || Float::INFINITY }
          return true if widest.nil?
          slots.each_index.all? do |index|
            same_value?(slots[index], values[index], values[widest])
          end
        end

        ##
        # Whether a slot's value is the widest one's, as far as the slot
        # goes: the same, or its start for a slot with a prefix. An
        # exploded list of one member writes what the member alone does,
        # so the two are the same. A slot left out agrees only where it
        # would write nothing: an empty value, in an expression with no
        # leader.
        #
        # @param [Slot] slot The slot.
        # @param [String, Array, Hash, nil] value Its value, decoded.
        # @param [String, Array, Hash] widest The widest value, decoded.
        def same_value?(slot, value, widest)
          widest = widest.first if widest.is_a?(Array) && widest.size == 1
          if value.nil?
            return widest == "" && slot.expression.class.leader.empty?
          end
          value = value.first if value.is_a?(Array) && value.size == 1
          prefix = slot.variable.prefix
          if prefix && widest.is_a?(String)
            widest[0, prefix] == value
          else
            widest == value
          end
        end

        # The next slot. Previous is the slot before it in its expression,
        # if any.
        def add(expression, variable, pattern, previous)
          absorbed = !previous.nil? && !pattern && !previous.pattern &&
            variable.explode && previous.variable.explode &&
            !expression.members_can_be_pairs?
          slot = Slot.new(expression, variable, @size, pattern, absorbed,
            false, nil)
          @size += 1
          slot.repeated = repeated_value(slot)
          slot
        end

        # Whether the expression right before a slot's takes every
        # character the slot could, so that it's empty_only: the slot is
        # the first of a default expression, as it is, and the expression
        # before has no leader, and nothing that limits what it takes.
        def takes_all_before?(slot, slots_before)
          variable = slot.variable
          return false unless slot.expression.instance_of?(OpPlain)
          return false if variable.explode || slot.pattern || slot.repeated
          return false unless slots_before.first.expression.class.leader.empty?
          slots_before.none? do |before|
            before.pattern || before.variable.prefix || before.repeated
          end
        end

        # A RepeatedValue for the slot if it repeats an earlier one's name
        # where it qualifies, or nil. It also notes what the later slots
        # need to know about this one.
        def repeated_value(slot)
          variable = slot.variable
          plain = !variable.explode && !slot.pattern
          first = @firsts[variable.name]
          qualifies = plain && first &&
            @values_up_to[variable.name] == @values
          if qualifies && !first.variable.prefix
            return RepeatedValue.new(first, slot)
          end
          @values += 1
          decided = plain && @start_decided &&
            slot.expression.end_decided?(variable)
          if decided && first.nil?
            @firsts[variable.name] = slot
            @values_up_to[variable.name] = @values
          end
          @start_decided = decided
          RepeatedValue.new(first, slot) if qualifies && !variable.prefix
        end
      end
    end
  end
end
