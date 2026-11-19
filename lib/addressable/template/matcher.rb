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
require "addressable/template/matcher/first_bytes"
require "addressable/template/matcher/character_set"
require "addressable/template/matcher/search"
require "addressable/template/matcher/states"

module Addressable
  class Template
    # The :machine engine's matcher.
    #
    # The nodes describe how they match by calling the builder methods
    # (#literal, #lazy_run, #optional, #capture, #repeat, ...), which add
    # states to a small graph. Each state knows what to try next, in order.
    # #match then searches the graph depth first, trying those choices in
    # the same order as the regexp Template builds, so it finds the same
    # split of the URI between the varspecs. It knows nothing about
    # operators.
    #
    # A plain depth-first search can take exponential time. This one
    # remembers each state and position it has tried: if it comes back to
    # one, that one already failed (or the search would have stopped), so
    # it's skipped. Each state is tried at most once per position, so the
    # time grows with the template's size times the URI's length.
    #
    # To try less, each state also knows which bytes a match from it can
    # start with (FirstBytes), and the search skips a state that can't
    # start with the byte at its position.
    #
    # The rest is in matcher/:
    #
    # - states.rb: the states, each answering #follow with the attempts
    #   to make next, in the order to try them.
    # - search.rb: what one call to #match keeps while it searches, and
    #   the Captures it gives back.
    # - character_set.rb: the characters each kind of value can hold.
    # - first_bytes.rb: FirstBytes.
    #
    # @api private
    class Matcher
      # The template's expressions as the pattern writes them, for
      # Matching.match_data.
      attr_reader :expansions

      def initialize(expansions)
        @expansions = expansions
        @encoding = nil
        @states = []
        @groups = 0
        # How many optional parts and repeats the states being added are
        # inside. Text outside all of them is required text.
        @optional_depth = 0
        @required_text = []
        @last_required_literal = nil
        @required_text_ends_uri = false
      end

      ##
      # Literal text, as units of [raw, encoded] (see Unit).
      #
      # :regexp's regexp holds the raw characters, so it takes the encoding
      # of the non-ASCII ones, and raises Encoding::CompatibilityError where
      # they're in two encodings, or where a URI with non-ASCII text is in
      # another. The matcher raises the same errors at the same points.
      def literal(units)
        units.each do |raw, _|
          next if raw.nil? || raw.ascii_only?
          if @encoding.nil?
            @encoding = raw.encoding
          elsif @encoding != raw.encoding
            raise Encoding::CompatibilityError,
              "incompatible character encodings: #{@encoding} and " \
              "#{raw.encoding}"
          end
        end
        # Text that only matches as written is joined into one unit, so a
        # literal is usually one comparison. Each joined unit starts as a
        # copy, so appending to it leaves the pattern's text alone.
        joined = []
        units.each do |raw, encoded|
          if encoded.nil? && joined.last && joined.last.encoded.nil?
            joined.last.raw << raw
          elsif encoded.nil?
            joined << Unit.new(raw.dup, nil)
          else
            joined << Unit.new(raw, encoded)
          end
        end
        state = add(Literal, joined)
        note_required_text(state, joined) if @optional_depth.zero?
        state
      end

      # Text that matches only as it is.
      def exact(text)
        literal([[text, nil]])
      end

      # Characters of a set, as few as can be first.
      def lazy_run(set)
        add(LazyRun, SETS.fetch(set))
      end

      # Characters of a set, as many as can be first.
      def greedy_run(set)
        add(GreedyRun, SETS.fetch(set))
      end

      # Every character of a set that follows, giving none back.
      def possessive_run(set)
        add(PossessiveRun, SETS.fetch(set))
      end

      # A value matched by a processor's pattern, a regexp's source.
      def processor_pattern(source)
        add(ProcessorPattern, source)
      end

      # The block's states, or nothing, tried in that order.
      def optional
        choice = add(Choice)
        choice.first = @states.size
        inside_optional { yield }
        choice.second = @states.size
      end

      # Nothing, or the block's states, tried in that order.
      def nothing_or
        choice = add(Choice)
        choice.second = @states.size
        inside_optional { yield }
        choice.first = @states.size
      end

      # Captures what the block's states match, in the next group.
      def capture
        slot = @groups * 2
        @groups += 1
        add(Capture, slot)
        yield
        add(Capture, slot + 1)
      end

      # One or more members, as the block's states, with the joiner between
      # them, as many as can be first. An optional joiner can leave a member
      # empty, and an empty member ends the value.
      def repeat(joiner, joiner_required)
        yield
        another = add(Choice)
        another.first = @states.size
        add(MemberStart)
        inside_optional do
          if joiner_required
            exact(joiner)
          else
            optional { exact(joiner) }
          end
          yield
        end
        member_end = add(MemberEnd)
        member_end.again = another.index
        member_end.after = @states.size
        another.second = @states.size
      end

      # Ends the template, links the states, and works out their first
      # bytes.
      def finish
        @required_text_ends_uri = !@last_required_literal.nil? &&
          @states.last.equal?(@last_required_literal)
        @required_text.freeze
        add(Done)
        @states.each { |state| state.link(@states) }
        changed = true
        while changed
          changed = false
          # Last first, since most states depend on the ones after them.
          @states.reverse_each do |state|
            bytes = state.possible_first_bytes
            next if bytes == state.first_bytes
            state.first_bytes = bytes
            changed = true
          end
        end
        @states.each(&:prepare)
        @states.freeze
        freeze
      end

      ##
      # Matches the whole URI, making the choices in order.
      #
      # @param [String] text The URI's text.
      #
      # @return [Captures, NilClass] The captures, or nil if it doesn't match.
      def match(text)
        if @encoding && @encoding != text.encoding && !text.ascii_only?
          raise Encoding::CompatibilityError,
            "incompatible encoding regexp match (#{@encoding} regexp with " \
            "#{text.encoding} string)"
        end
        return nil unless holds_required_text?(text)
        search = Search.new(text)
        to_try = [Attempt.new(@states.first, 0, nil, false)]
        until to_try.empty?
          attempt = to_try.pop
          # The same state at the same position always ends the same way,
          # and the first time it failed, or we'd have stopped.
          next unless search.first_time?(attempt)
          if attempt.state.is_a?(Done) && attempt.position == search.size
            return captures(text, attempt.captures)
          end
          # Pushed in reverse, so the first one is tried first.
          attempt.state.follow(attempt, search).reverse_each do |next_attempt|
            to_try << next_attempt
          end
        end
        nil
      end

      private

      # Adds the block's states as ones a match can leave out or repeat.
      def inside_optional
        @optional_depth += 1
        yield
      ensure
        @optional_depth -= 1
      end

      # Notes the literal's text that only matches as written: every match
      # takes it, in order, so the URI has to hold it. A unit that may also
      # be pct-encoded is left out, which splits the text into pieces.
      # Only a literal whose text ends that way can make the URI end with
      # it.
      def note_required_text(state, units)
        units.each { |unit| @required_text << unit.raw if unit.encoded.nil? }
        @last_required_literal = units.last.encoded.nil? ? state : nil
      end

      ##
      # Whether the URI holds the required text, each piece after the one
      # before it, and ends with the last one if the template ends with
      # it. A URI that doesn't can't match, so it's rejected without a
      # search. This is what rejects a URI missing a literal the template
      # ends with, which would otherwise take the search through every
      # split of the text before it. Positions here count characters, as
      # String#index does.
      #
      # @param [String] text The URI's text.
      #
      # @return [TrueClass, FalseClass]
      def holds_required_text?(text)
        from = 0
        last = @required_text.size - 1
        @required_text.each_with_index do |piece, i|
          if i == last && @required_text_ends_uri
            return text.end_with?(piece) &&
              text.length - piece.length >= from
          end
          found = text.index(piece, from)
          return false unless found
          from = found + piece.length
        end
        true
      end

      def add(type, *arguments)
        state = type.new(@states.size, *arguments)
        @states << state
        state
      end

      # The latest position noted for each slot.
      def captures(text, list)
        slots = Array.new(@groups * 2)
        while list
          slots[list.slot] = list.position if slots[list.slot].nil?
          list = list.rest
        end
        Captures.new(text, slots)
      end
    end
  end
end
