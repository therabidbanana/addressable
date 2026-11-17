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
    # @api private
    class Matcher
      # The bytes a match from a state can start with, and whether it can
      # be at the end of the URI without taking anything. It may include
      # bytes that can't start a match, but never leaves one out, so
      # skipping a state whose first bytes don't include the next byte
      # never changes the result. Kept as one Integer, with bit n for byte
      # n, so that joining two is one "|".
      class FirstBytes
        END_OF_URI = 256

        attr_reader :mask

        def initialize(mask = 0)
          @mask = mask
        end

        def self.bytes(*bytes)
          new(bytes.inject(0) { |mask, byte| mask | (1 << byte) })
        end

        # Both sets' bytes. One that already has them all is reused, so
        # working the sets out again changes nothing and makes nothing new.
        def |(other)
          joined = mask | other.mask
          if joined == mask
            self
          elsif joined == other.mask
            other
          else
            FirstBytes.new(joined)
          end
        end

        def ==(other)
          other.is_a?(FirstBytes) && mask == other.mask
        end

        # Whether a match can start at the position: with the byte there,
        # or at the end of the URI.
        def allow?(search, position)
          byte = position < search.size ? search.text.getbyte(position) :
            END_OF_URI
          mask[byte] == 1
        end

        def disjoint?(other)
          (mask & other.mask).zero?
        end
      end

      # Every state's first bytes before Matcher#finish works them out.
      NOTHING = FirstBytes.new
      # A processor's pattern can start with anything, or match nothing.
      ANYTHING = FirstBytes.new((1 << (FirstBytes::END_OF_URI + 1)) - 1)
      # Where the template ends: nothing but the end of the URI can follow.
      ONLY_END_OF_URI = FirstBytes.bytes(FirstBytes::END_OF_URI)

      # The characters a variable's value can contain, as Template's regexp
      # classes have them: some ASCII characters, any pct-encoded triplet,
      # and any non-ASCII character.
      class CharacterSet
        # The bytes a character of the set can start with: an ASCII
        # character in the set, "%", or any non-ASCII byte.
        attr_reader :first_bytes

        def initialize(characters)
          pattern = Regexp.new("[#{characters}]")
          @ascii = Array.new(128) { |byte| pattern =~ byte.chr ? true : false }
          ascii = (0...128).select { |byte| @ascii[byte] }
          @first_bytes = FirstBytes.bytes(37, *ascii, *(0x80..0xFF))
        end

        ##
        # Where the character at the position ends, if it's in the set.
        #
        # @param [String] text The URI, valid UTF-8.
        # @param [Integer] position A byte offset.
        #
        # @return [Integer, NilClass] The byte offset after the character.
        def character_end(text, position)
          byte = text.getbyte(position)
          if byte.nil?
            nil
          elsif byte >= 0xF0
            position + 4
          elsif byte >= 0xE0
            position + 3
          elsif byte >= 0x80
            position + 2
          elsif @ascii[byte]
            position + 1
          elsif byte == 37 && hex?(text.getbyte(position + 1)) &&
              hex?(text.getbyte(position + 2))
            position + 3
          end
        end

        private

        def hex?(byte)
          !byte.nil? && ((byte >= 48 && byte <= 57) ||
            (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102))
        end
      end

      unreserved = Addressable::URI::CharacterClasses::UNRESERVED
      reserved = Addressable::URI::CharacterClasses::RESERVED + unreserved
      SETS = {
        unreserved: CharacterSet.new(unreserved),
        # A label's value, which can't contain "." unless it's delimited.
        unreserved_no_dot: CharacterSet.new(unreserved.gsub("\\.", "")),
        reserved: CharacterSet.new(reserved),
        # A + or # value before the last, which ends at a comma.
        reserved_no_comma: CharacterSet.new(reserved.delete(","))
      }.freeze

      # A piece of literal text. Raw matches as it is; encoded, if there is
      # one, is the pct-encoded form of a non-ASCII character, whose hex
      # digits match in either case. Either can be nil.
      Unit = Struct.new(:raw, :encoded) do
        # Where the unit ends if it's at the position, or nil. casecmp
        # folds ASCII letters only, and compares bytes even where the slice
        # splits a character.
        def match_end(text, position)
          if raw && text.byteslice(position, raw.bytesize) == raw
            position + raw.bytesize
          elsif encoded &&
              text.byteslice(position, encoded.bytesize).casecmp(encoded) == 0
            position + encoded.bytesize
          end
        end

        # The bytes the unit can start with: raw's first, and encoded's
        # first in either case.
        def first_bytes
          bytes = []
          bytes << raw.getbyte(0) if raw
          if encoded
            byte = encoded.getbyte(0)
            bytes << byte
            bytes << (byte ^ 32) if (byte | 32) >= 97 && (byte | 32) <= 122
          end
          FirstBytes.bytes(*bytes)
        end
      end

      # One place the search can be: a state, a position in the URI, the
      # captures so far, and whether the current member of an exploded
      # value hasn't matched anything yet.
      Attempt = Struct.new(:state, :position, :captures, :empty) do
        # The attempt at another state and position, with the same
        # captures. Taking any text means the member isn't empty any more.
        def move(state, position)
          Attempt.new(state, position, captures,
            empty && position == self.position)
        end
      end

      # The captures, as a list from the latest back to the first, so an
      # attempt adds one without copying the others.
      CaptureList = Struct.new(:slot, :position, :rest)

      # What the search keeps for one URI: the text, the attempts tried,
      # and where runs of each set end.
      class Search
        attr_reader :text, :size

        def initialize(text)
          @text = text
          @size = text.bytesize
          @tried = {}
          @run_ends = {}
        end

        # Whether this is the first time the search reaches the attempt's
        # state and position (with the member's emptiness). The captures
        # don't change whether the rest can match, so they're left out.
        def first_time?(attempt)
          key = ((attempt.state.index * (@size + 1) + attempt.position) * 2) +
            (attempt.empty ? 1 : 0)
          return false if @tried[key]
          @tried[key] = true
        end

        # Where the longest run of the set starting at the position ends.
        # Every position in a run ends at the same place, so the whole run
        # is filled in once, and each later question about it is answered
        # without reading it again.
        def run_end(set, position)
          ends = (@run_ends[set] ||= {})
          walked = []
          at = position
          until ends.key?(at)
            following = set.character_end(@text, at)
            unless following
              ends[at] = at
              break
            end
            walked << at
            at = following
          end
          walked.each { |start| ends[start] = ends[at] }
          ends[position]
        end

        ##
        # Where a processor's pattern can end, starting at the position, in
        # the order Ruby's regexp engine prefers them. The engine only gives
        # its first choice, so each later one comes from matching again with
        # every end found so far ruled out, as template_match_spec.rb's
        # end_positions does. Regexp offsets count characters, and the
        # search's count bytes.
        #
        # @param [Regexp] pattern The pattern, starting with \G.
        # @param [Integer] position A byte offset.
        #
        # @return [Array<Integer>] Byte offsets.
        def pattern_ends(pattern, position)
          start = @text.byteslice(0, position).length
          characters = @text.length
          ends = []
          while true
            ruled_out = ends.map do |finish|
              "(?m:.{#{characters - finish}})\\z"
            end
            source = pattern.source
            source += "(?!#{ruled_out.join("|")})" unless ruled_out.empty?
            found = Regexp.new(source).match(@text, start)
            break unless found
            ends << found.end(0)
          end
          ends.map { |finish| @text[0, finish].bytesize }
        end
      end

      # A state in the graph. Each one moves on to the state added after it
      # unless it says otherwise.
      class State
        attr_reader :index
        # See FirstBytes. Matcher#finish works them out.
        attr_accessor :first_bytes

        def initialize(index)
          @index = index
          @first_bytes = NOTHING
        end

        # Points the state at the states it moves on to, once all of them
        # exist.
        def link(states)
          @next = states[@index + 1]
        end

        # Works out anything that depends on the first bytes, once they're
        # known.
        def prepare
        end

        # The first bytes, from the states it moves on to. Loops make a
        # state depend on itself, so Matcher#finish asks again until no
        # answer changes.
        def possible_first_bytes
          @next.first_bytes
        end
      end

      # Text that has to come next.
      class Literal < State
        def initialize(index, units)
          super(index)
          @units = units
          # A literal doesn't depend on what follows it, so its first bytes
          # are known now.
          @text_first_bytes = units.first.first_bytes
        end

        def possible_first_bytes
          @text_first_bytes
        end

        def follow(attempt, search)
          position = attempt.position
          @units.each do |unit|
            position = unit.match_end(search.text, position)
            return [] unless position
          end
          [attempt.move(@next, position)]
        end
      end

      # A run of a set's characters, as short as possible first: stop here,
      # or take one more character and ask again.
      class LazyRun < State
        def initialize(index, set)
          super(index)
          @set = set
        end

        def possible_first_bytes
          @set.first_bytes | @next.first_bytes
        end

        # If what follows can't start with any character of the set, the
        # run can only stop where the set stops. Asked once the first bytes
        # are known.
        def prepare
          @stops_where_set_stops = @set.first_bytes.disjoint?(@next.first_bytes)
        end

        def follow(attempt, search)
          position = attempt.position
          if @stops_where_set_stops
            return [attempt.move(@next, search.run_end(@set, position))]
          end
          attempts = []
          # Stopping here only helps if what follows can start here.
          if @next.first_bytes.allow?(search, position)
            attempts << attempt.move(@next, position)
          end
          after = @set.character_end(search.text, position)
          attempts << attempt.move(self, after) if after
          attempts
        end
      end

      # A run of a set's characters, as long as possible first: take one
      # more character and ask again, or stop here.
      class GreedyRun < LazyRun
        def follow(attempt, search)
          super.reverse
        end
      end

      # Every character of the set that follows, with no other choice.
      class PossessiveRun < LazyRun
        def follow(attempt, search)
          [attempt.move(@next, search.run_end(@set, attempt.position))]
        end
      end

      # Two ways on from the same place, tried in order: an optional part
      # or the part left out, for example. A way on is only tried if it
      # can start with the byte here.
      class Choice < State
        attr_accessor :first, :second

        def link(states)
          @first_state = states[first]
          @second_state = states[second]
        end

        def possible_first_bytes
          @first_state.first_bytes | @second_state.first_bytes
        end

        def follow(attempt, search)
          position = attempt.position
          attempts = []
          if @first_state.first_bytes.allow?(search, position)
            attempts << attempt.move(@first_state, position)
          end
          if @second_state.first_bytes.allow?(search, position)
            attempts << attempt.move(@second_state, position)
          end
          attempts
        end
      end

      # A value matched by a processor's pattern: a regexp the caller gives,
      # which Template puts in its own regexp as it is. Its ends are tried
      # in the order Ruby's regexp engine prefers them (Search#pattern_ends).
      # The pattern can backtrack however it was written, so with one,
      # matching is only as fast as the pattern, as it is with Template.
      class ProcessorPattern < State
        def initialize(index, source)
          super(index)
          # Compiled now, so a pattern that isn't valid raises RegexpError
          # before any matching, as it does from Template's regexp.
          @pattern = Regexp.new("\\G(?:#{source})")
        end

        def possible_first_bytes
          ANYTHING
        end

        def follow(attempt, search)
          search.pattern_ends(@pattern, attempt.position).map do |finish|
            attempt.move(@next, finish)
          end
        end
      end

      # Notes the position, as the start or the end of a variable's value.
      class Capture < State
        def initialize(index, slot)
          super(index)
          @slot = slot
        end

        def follow(attempt, _search)
          captures = CaptureList.new(@slot, attempt.position, attempt.captures)
          [Attempt.new(@next, attempt.position, captures, attempt.empty)]
        end
      end

      # The start of an exploded value's next member: nothing taken yet.
      class MemberStart < State
        def follow(attempt, _search)
          [Attempt.new(@next, attempt.position, attempt.captures, true)]
        end
      end

      # The end of an exploded value's member. Another member follows, as
      # in Ruby's regular expressions, unless this one matched nothing,
      # which ends the value.
      class MemberEnd < State
        attr_accessor :again, :after

        def link(states)
          @again_state = states[again]
          @after_state = states[after]
        end

        def possible_first_bytes
          @again_state.first_bytes | @after_state.first_bytes
        end

        def follow(attempt, _search)
          state = attempt.empty ? @after_state : @again_state
          [Attempt.new(state, attempt.position, attempt.captures, false)]
        end
      end

      # The end of the template. The URI has to end here too.
      class Done < State
        def link(_states)
        end

        def possible_first_bytes
          ONLY_END_OF_URI
        end

        def follow(_attempt, _search)
          []
        end
      end

      # A match's captures, as a regular expression's MatchData gives them
      # to Matching.match_data. Positions are byte offsets, which
      # match_data only compares with each other.
      class Captures
        def initialize(text, slots)
          @text = text
          @slots = slots
        end

        def captures
          (0...(@slots.size / 2)).map do |group|
            first = @slots[group * 2]
            last = @slots[group * 2 + 1]
            first && last ? @text.byteslice(first, last - first) : nil
          end
        end

        # Where the group (1 for the first varspec) begins, or nil if it
        # didn't take part in the match.
        def begin(group)
          @slots[group * 2 - 1] && @slots[group * 2 - 2]
        end

        # Where the group ends, or nil if it didn't take part in the match.
        def end(group)
          @slots[group * 2 - 2] && @slots[group * 2 - 1]
        end
      end

      # The template's expressions as the pattern writes them, for
      # Matching.match_data.
      attr_reader :expansions

      def initialize(expansions)
        @expansions = expansions
        @encoding = nil
        @states = []
        @groups = 0
      end

      ##
      # Literal text, as units of [raw, encoded] (see Unit).
      #
      # Template's regexp holds the raw characters, so it takes the encoding
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
        # literal is usually one comparison.
        joined = []
        units.each do |raw, encoded|
          if encoded.nil? && joined.last && joined.last.encoded.nil?
            joined.last.raw += raw
          else
            joined << Unit.new(raw, encoded)
          end
        end
        add(Literal, joined)
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
        yield
        choice.second = @states.size
      end

      # Nothing, or the block's states, tried in that order.
      def nothing_or
        choice = add(Choice)
        choice.second = @states.size
        yield
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
        if joiner_required
          exact(joiner)
        else
          optional { exact(joiner) }
        end
        yield
        member_end = add(MemberEnd)
        member_end.again = another.index
        member_end.after = @states.size
        another.second = @states.size
      end

      # Ends the template, links the states, and works out their first
      # bytes.
      def finish
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
