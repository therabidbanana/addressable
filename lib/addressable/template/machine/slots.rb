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
      # - repeated: a RepeatedValue if it matches only an earlier varspec's
      #   value, and otherwise nil.
      #
      # A slot with neither matches a value of its own.
      #
      # @api private
      Slot = Struct.new(:expression, :variable, :group, :pattern, :absorbed,
        :repeated)

      ##
      # A template's slots: one for each varspec, in order, worked out
      # before any of the matcher's states are added, so that each
      # expression adds its steps from what's already decided
      # (Expression#add_match_steps).
      #
      # A varspec is absorbed if it's an exploded variable right after
      # another exploded one in its expression, which takes every member it
      # could, since the earlier variable wins. {;a*,b*} matches like
      # {;a*}. A processor's pattern can give either one other text, so a
      # variable with one, or after one, isn't absorbed.
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
          nodes.grep(Expression).each do |expression|
            previous = nil
            @by_expression[expression] = expression.variables.map do |variable|
              pattern = processor && processor.match(variable.name)
              previous = add(expression, variable, pattern, previous)
            end
          end
        end

        # The node's slots, in order. A literal has none.
        def of(node)
          @by_expression.fetch(node, NONE)
        end

        private

        # The next slot. Previous is the slot before it in its expression,
        # if any.
        def add(expression, variable, pattern, previous)
          absorbed = !previous.nil? && !pattern && !previous.pattern &&
            variable.explode && previous.variable.explode
          slot = Slot.new(expression, variable, @size, pattern, absorbed, nil)
          @size += 1
          slot.repeated = repeated_value(slot)
          slot
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
