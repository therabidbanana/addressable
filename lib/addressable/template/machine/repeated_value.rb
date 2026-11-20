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

require "addressable/uri"
require "addressable/template/values"
require "addressable/template/matcher/character_set"

module Addressable
  class Template
    module Machine
      ##
      # Finds the varspecs that repeat an earlier one's name, going through
      # the template's varspecs in order (Expression#add_match_steps).
      # Each later one becomes a RepeatedValue, which matches only the
      # earlier value, where that value's place in the URI is decided:
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
      # given winning.
      #
      # @api private
      class RepeatedNames
        # The earlier varspec with a name: its expression, variable and
        # group, and how many values of their own came up to it.
        First = Struct.new(:expression, :variable, :group, :values)

        def initialize
          @firsts = {}
          # How many varspecs with values of their own so far.
          @values = 0
          # Whether the next value's start is decided.
          @start_decided = true
        end

        ##
        # Notes the template's next varspec, and gives a RepeatedValue for
        # it if it repeats an earlier one's name where it qualifies, or
        # nil. Only varspecs that aren't exploded and have no processor
        # pattern count.
        #
        # An earlier varspec with a prefix has only the start of the value,
        # so a later one without matches a value of its own, which has to
        # start with the earlier one's (RepeatedValue#extends?). Two with
        # prefixes match as if the name were written once.
        #
        # @param [Expression] expression The varspec's expression.
        # @param [Variable] variable The varspec.
        # @param [Integer] group The varspec's group.
        # @param [Object, nil] pattern The processor's pattern for it.
        #
        # @return [RepeatedValue, nil]
        def note(expression, variable, group, pattern)
          plain = !variable.explode && !pattern
          first = @firsts[variable.name]
          qualifies = plain && first && first.values == @values
          if qualifies && !first.variable.prefix
            return RepeatedValue.new(first, expression, variable)
          end
          @values += 1
          decided = plain && @start_decided &&
            expression.end_decided?(variable)
          if decided && first.nil?
            @firsts[variable.name] =
              First.new(expression, variable, group, @values)
          end
          @start_decided = decided
          if qualifies && !variable.prefix
            RepeatedValue.new(first, expression, variable)
          end
        end
      end

      ##
      # A varspec whose name an earlier one in the template already has.
      # Expansion writes the same value in both, so the later one matches
      # only the value the earlier one took, as the later one writes it
      # (Matcher#same_value), and is left out only where the earlier one is
      # (#left_out?). /{lang}/docs{?lang} matches "/en/docs?lang=en", but
      # not "/en/docs?lang=fr" or "/en/docs", which no expansion writes.
      #
      # It's only for varspecs that aren't exploded and have no processor
      # pattern, with no prefix on the earlier one (Expression
      # #add_match_steps). A later one with a prefix matches the start of
      # the value.
      #
      # @api private
      class RepeatedValue
        # Characters expansion writes differently from how a URI has them:
        # each one it pct-encodes, and a "%", since the value is decoded
        # first. By whether the operator keeps reserved characters.
        CHANGED_BY_EXPANSION = {
          false => /[^#{Addressable::URI::CharacterClasses::UNRESERVED}]/,
          true => /%|[^#{Addressable::URI::CharacterClasses::RESERVED}#{
            Addressable::URI::CharacterClasses::UNRESERVED}]/
        }.freeze

        # The group of the earlier varspec.
        attr_reader :first_group

        ##
        # @param [RepeatedNames::First] first The earlier varspec.
        # @param [Expression] expression The later varspec's expression.
        # @param [Variable] variable The later varspec.
        def initialize(first, expression, variable)
          @first_expression = first.expression
          @first_variable = first.variable
          @first_group = first.group
          @expression = expression
          @variable = variable
          @set = Matcher::SETS.fetch(expression.value_set(variable))
        end

        # Whether the earlier varspec has a prefix and this one doesn't, so
        # this one matches a value of its own that has to start with the
        # earlier one's (#starts_with_first?), rather than the earlier one's
        # value (#length_at).
        def extends?
          @first_variable.prefix ? true : false
        end

        ##
        # Whether this varspec's value, cut to the earlier one's prefix,
        # is the earlier one's, both decoded. Where the earlier one was left
        # out, this one's value has to be empty, and the earlier one has to
        # write nothing for an empty value.
        #
        # @param [String, nil] first_text The earlier varspec's text.
        # @param [String] text This varspec's text.
        #
        # @return [TrueClass, FalseClass]
        def starts_with_first?(first_text, text)
          value = decoded(raw_value(text, @expression, @variable))
          if first_text.nil?
            return @first_expression.class.leader.empty? && value.empty?
          end
          first = decoded(raw_value(first_text, @first_expression,
            @first_variable))
          value[0, @first_variable.prefix] == first
        end

        ##
        # How many bytes the later varspec takes at the position, writing
        # the earlier one's value: the name a ;, ? or & expression writes,
        # then the value, written as the earlier one's text has it, if the
        # later one can hold that, or as expansion writes it. Where the
        # earlier varspec was left out, the later one can only take an empty
        # value, and only if the earlier one writes nothing for one.
        #
        # @param [Matcher::Search] search The search.
        # @param [Integer] position A byte offset.
        # @param [String, nil] first_text
        #   The earlier varspec's text, or nil if it was left out.
        #
        # @return [Integer, nil] The length, or nil if it isn't there.
        def length_at(search, position, first_text)
          raw = first_text &&
            raw_value(first_text, @first_expression, @first_variable)
          if raw.nil?
            return nil unless @first_expression.class.leader.empty?
            raw = ""
          end
          name = name_text(raw)
          text = search.text
          return nil unless text.byteslice(position, name.bytesize) == name
          start = position + name.bytesize
          finish = value_end(search, start, raw)
          finish && finish - position
        end

        ##
        # Whether the later varspec can be left out: where the earlier one
        # was, or where the later one writes nothing for its value, which is
        # an empty value without a leader.
        #
        # @param [String, nil] first_text
        #   The earlier varspec's text, or nil if it was left out.
        #
        # @return [TrueClass, FalseClass]
        def left_out?(first_text)
          return true if first_text.nil?
          @expression.class.leader.empty? &&
            raw_value(first_text, @first_expression, @first_variable).empty?
        end

        private

        # A varspec's value as the URI has it: its text, without the name
        # and "=" that a ;, ? or & expression writes first.
        def raw_value(text, expression, variable)
          return text unless expression.class.names_values?
          text.byteslice(variable.name.bytesize + 1, text.bytesize) || ""
        end

        # A value with its pct-encoded triplets decoded, as Matching gives
        # it.
        def decoded(raw)
          Addressable::URI.unencode_component(raw)
        end

        # What the later varspec's operator writes before the value: the
        # name and "=", or for ; and an empty value, the name alone.
        def name_text(raw)
          return "" unless @expression.class.names_values?
          name = @variable.name
          raw.empty? && @expression.is_a?(OpPathParams) ? name : "#{name}="
        end

        # Where the value ends, if it starts at the position: as the earlier
        # varspec's text has it, cut to the later one's prefix, or as
        # expansion writes it, where that's different.
        def value_end(search, start, raw)
          prefix = @variable.prefix
          written = prefix ? Values.prefix(raw, prefix, true) : raw
          return start + written.bytesize if holds?(search, start, written)
          return nil unless raw =~ CHANGED_BY_EXPANSION[@variable.allows_reserved?]
          expanded = Values.encode_string(
            decoded(raw), @variable.allows_reserved?, prefix
          )
          start + expanded.bytesize if holds?(search, start, expanded)
        end

        # Whether the URI has the text at the position, in characters the
        # later varspec's value can hold.
        def holds?(search, start, text)
          search.text.byteslice(start, text.bytesize) == text &&
            search.run_end(@set, start) >= start + text.bytesize
        end
      end
    end
  end
end
