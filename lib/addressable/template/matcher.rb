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
    # (#literal, #greedy_run, #optional, #capture, #repeat, ...), which add
    # states to a small graph. Each state knows what to try next, in order.
    # #match then searches the graph depth first, trying those choices in
    # order, and the first way through the graph gives the split of the
    # URI between the varspecs. The nodes order the choices so that the
    # earlier variable takes what it can (Expression#add_match_steps). It
    # knows nothing about operators.
    #
    # A plain depth-first search can take exponential time. This one
    # remembers each state and position it has tried: if it comes back to
    # one, that one already failed (or the search would have stopped), so
    # it's skipped. It only needs to remember states that branch (choices,
    # runs that can stop at more than one place, processor patterns).
    # Every other state has one way on, and every loop in the graph passes
    # through a state that branches, so from each branch the search takes
    # at most as many steps as the template has states before it reaches
    # another. The time grows with the URI's length times the template's
    # size, squared at worst.
    #
    # To try less, each state also knows which bytes a match from it can
    # start with (FirstBytes), and the search skips a state that can't
    # start with the byte at its position. A greedy run also knows
    # when what follows it can only start inside a run of its characters
    # if a certain byte comes after that run (State#bytes_after_run), and
    # otherwise only stops at the run's end. Where what follows starts
    # with literal text the run could hold, it only stops where that text
    # occurs (State#leading_text).
    #
    # The rest is in matcher/:
    #
    # - states.rb: the states, each of which #follow hands the attempts to
    #   make next to the search (Search#try).
    # - search.rb: what one call to #match keeps while it searches, and
    #   the Captures it gives back.
    # - character_set.rb: the characters each kind of value can hold.
    # - first_bytes.rb: FirstBytes.
    #
    # @api private
    class Matcher
      # @param [Integer] groups
      #   How many groups the template has: one for each varspec's value,
      #   numbered in order from 0 (Machine::Slots).
      def initialize(groups)
        @encoding = nil
        @states = []
        @groups = groups
        # How many optional parts and repeats the states being added are
        # inside. Text outside all of them is required text.
        @optional_depth = 0
        # The groups whose captures the states being added are inside.
        @capturing = []
        @required_text = []
        @last_required_literal = nil
        @required_text_ends_uri = false
        # For each group a later state reads, the states that end its
        # capture and those that read it.
        @capture_ends = Hash.new { |hash, group| hash[group] = [] }
        @readers = Hash.new { |hash, group| hash[group] = [] }
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

      ##
      # The block's states, tried first so that one of the texts has to
      # follow them, and then as they are. With runs that take as much as
      # they can, the first try stops before the last place a text follows.
      # The block is called twice.
      #
      # @param [Array<String>] texts ASCII text.
      def preferring_followed_by(texts)
        choice = add(Choice)
        choice.first = @states.size
        inside_optional { yield }
        add(FollowedBy, texts)
        to_end = jump_ahead
        choice.second = @states.size
        inside_optional { yield }
        land([to_end])
      end

      # One character of a set.
      def one_character(set)
        add(OneCharacter, SETS.fetch(set))
      end

      # Characters of a set, as many as can be first.
      def greedy_run(set)
        add(GreedyRun, SETS.fetch(set))
      end

      ##
      # Characters of a set that can hold "?" and "#", stopping at the
      # first "?" or "#" where what follows can match, and otherwise as
      # many as can be first. "?" and "#" start a URI's query and fragment,
      # so /files/{+path}{?q} gives "a/b?q=c" to path and q as "a/b" and
      # "c", not all to path, though path could hold it.
      def reserved_run(set)
        choice = add(Choice)
        choice.first = @states.size
        add(DelimiterRun, SETS.fetch(set))
        to_end = jump_ahead
        choice.second = @states.size
        greedy_run(set)
        land([to_end])
      end

      ##
      # At most a number of characters of a set, as many as can be first,
      # for a value with a prefix modifier (CappedRun).
      #
      # @param [Symbol] set The set's name.
      # @param [Integer] length The most characters it takes, decoded.
      # @param [TrueClass, FalseClass] at_least_one
      #   Whether it has to take a character.
      # @param [TrueClass, FalseClass] delimiters_first
      #   Whether it first tries stopping at each "?" or "#" in it, the
      #   first one first, as #reserved_run does.
      def capped_run(set, length, at_least_one: false, delimiters_first: false)
        add(CappedRun, SETS.fetch(set), length, at_least_one, delimiters_first)
      end

      # Every character of a set that follows, giving none back.
      def possessive_run(set)
        add(PossessiveRun, SETS.fetch(set))
      end

      # A value matched by a processor's pattern, a regexp's source.
      def processor_pattern(source)
        add(ProcessorPattern, source)
      end

      ##
      # A value that has to be an earlier group's: the writer says how much
      # of the URI is that value, written for this place.
      #
      # @param [Integer] group The earlier group.
      # @param [#length_at, #left_out?] writer
      #   #length_at takes the search, a position and the earlier group's
      #   text (nil if it took no part), and gives the length taken, or nil.
      def same_value(group, writer)
        reads(group, add(SameValue, group, writer))
      end

      ##
      # Goes on only where the writer says the group's value agrees with
      # the earlier group's.
      #
      # @param [Integer] earlier The earlier group.
      # @param [Integer] group The group just captured.
      # @param [#starts_with_first?] writer
      #   Takes the earlier group's text (nil if it took no part) and this
      #   group's, and says whether they agree.
      def starts_with(earlier, group, writer)
        reads(earlier, add(StartsWith, earlier, group, writer))
      end

      ##
      # The block's states, or nothing where the writer allows the value
      # that has to be the earlier group's to be left out, tried in that
      # order.
      #
      # @param [Integer] group The earlier group.
      # @param [#left_out?] writer
      #   Takes the earlier group's text (nil if it took no part), and says
      #   whether the value can be left out.
      def optional_same_value(group, writer)
        choice = add(Choice)
        choice.first = @states.size
        inside_optional { yield }
        to_end = jump_ahead
        choice.second = @states.size
        reads(group, add(LeftOut, group, writer))
        land([to_end])
      end

      # The block's states, or nothing, tried in that order.
      def optional
        choice = add(Choice)
        choice.first = @states.size
        inside_optional { yield }
        choice.second = @states.size
      end

      ##
      # Nothing where one of the texts follows, if the rest can match from
      # there; otherwise the block's states, or nothing, tried in that
      # order.
      #
      # @param [Array<String>] texts ASCII text.
      def optional_unless_followed_by(texts)
        choice = add(Choice)
        choice.first = @states.size
        add(FollowedBy, texts)
        to_end = jump_ahead
        choice.second = @states.size
        optional { yield }
        land([to_end])
      end

      # Captures what the block's states match, in the group. A group can
      # be captured in more than one place, since a value can be reached
      # more than one way; a match only passes through one of them.
      def capture(group)
        add(Capture, group, :start)
        @capturing << group
        yield
        @capturing.pop
        @capture_ends[group] << add(Capture, group, :end)
      end

      # Goes on if the value being captured has taken something, and
      # otherwise leaves it out, going on where #land points it. It's
      # added inside #capture's block.
      def leave_out_if_empty
        add(LeaveOutIfEmpty, @capturing.last)
      end

      # Goes on to a state that hasn't been added yet, which #land marks.
      def jump_ahead
        add(Jump, nil)
      end

      # Points the jumps (or LeaveOutIfEmpty states) at the next state
      # added.
      def land(jumps)
        jumps.each { |jump| jump.target = @states.size }
      end

      # The block's states as many times over as they match, as many as can
      # be first, then what follows. The block has to take at least one
      # character each time.
      def zero_or_more
        again = add(Choice)
        again.first = @states.size
        inside_optional { yield }
        add(Jump, again.index)
        again.second = @states.size
      end

      # One or more members, as the block's states, with the joiner between
      # them, as many as can be first.
      def repeat(joiner)
        yield
        zero_or_more do
          exact(joiner)
          yield
        end
      end

      ##
      # One or more members, as the block's states, with the joiner between
      # them, stopping after the first member that one of the texts
      # follows, if the rest can match from there, and otherwise as many as
      # can be first.
      #
      # @param [Array<String>] texts ASCII text.
      def repeat_stopping_before(joiner, texts)
        yield
        stop = add(Choice)
        stop.first = @states.size
        add(FollowedBy, texts)
        to_end = jump_ahead
        stop.second = @states.size
        more = add(Choice)
        more.first = @states.size
        inside_optional do
          exact(joiner)
          yield
        end
        add(Jump, stop.index)
        more.second = @states.size
        land([to_end])
      end

      # Ends the template, links the states, and works out their first
      # bytes.
      def finish
        @required_text_ends_uri = !@last_required_literal.nil? &&
          @states.last.equal?(@last_required_literal)
        @required_text.freeze
        add(Done)
        @states.each { |state| state.link(@states) }
        @states.select(&:branches?).each_with_index do |state, row|
          state.memo_row = row
        end
        note_dependencies
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
      # @param [Search] search
      #   What the search keeps. A caller that gives its own can read what
      #   was tried afterwards (Search#memo).
      #
      # @yield [texts]
      #   Without a block, the first way through the graph is the match.
      #   With one, each way found is offered to it in turn, as the text
      #   each group captured, until it takes one (Search#run).
      # @yieldreturn [Boolean] Whether to stop at this way through.
      #
      # @return [Array<String, nil>, NilClass]
      #   The text each group captured, in order, with nil for a group
      #   that took no part; or nil if the URI doesn't match.
      def match(text, search = Search.new(text))
        if @encoding && @encoding != text.encoding && !text.ascii_only?
          raise Encoding::CompatibilityError,
            "incompatible encoding regexp match (#{@encoding} regexp with " \
            "#{text.encoding} string)"
        end
        return nil unless holds_required_text?(text)
        search.try(@states.first, 0)
        found = search.run(@states.last) do
          !block_given? || yield(search.captures(@groups))
        end
        search.captures(@groups) if found
      end

      ##
      # The graph, a state to a line: its number, its kind and what it
      # holds (State#to_s). A state goes on to the next one unless its line
      # names others. For reading how a template matches, and for the
      # specs that pin it.
      #
      # @return [String]
      def to_s
        width = (@states.size - 1).to_s.size
        @states.map do |state|
          "#{state.index.to_s.rjust(width)} #{state}"
        end.join("\n")
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

      # Notes that the state reads the group's capture.
      def reads(group, state)
        @readers[group] << state
        state
      end

      ##
      # Gives each state that branches the groups whether the rest can
      # match from it depends on: those whose capture has ended before it
      # and that a state at or after it reads (SameValue, LeftOut). The
      # search remembers such a state at a position once for each place
      # those groups were captured (Search#first_time?), since a later
      # value may only match one of them. A template with no name written
      # twice has none, so this costs it nothing.
      def note_dependencies
        @readers.each do |group, readers|
          ends = @capture_ends[group]
          next if ends.empty?
          from = ends.map(&:index).min
          to = readers.map(&:index).max
          @states[(from + 1)..to].each do |state|
            state.depends_on += [group] if state.branches?
          end
        end
      end
    end
  end
end
