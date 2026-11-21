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

require "strscan"
require "addressable/template/matcher/memo"
require "addressable/template/matcher/units"

module Addressable
  class Template
    class Matcher
      # Where a piece of literal text occurs in the URI: the places found
      # so far, in order, and where to look for the next one, or nil once
      # there are no more.
      Occurrences = Struct.new(:places, :from)

      ##
      # What the search keeps for one URI: the text, the attempts to make
      # and those tried, the captures, where runs of each set end, and
      # where literal text occurs.
      #
      # The captures are one array of slots, two for each group: where its
      # value starts and where it ends, or nil. Only this class numbers
      # them; the states name a group (#start_capture, #end_capture,
      # #leave_out, #start_of, #span). Every attempt on the list has to
      # see the captures as they were when it was added, though the
      # attempts made before it change them. So a capture is undone rather
      # than copied: setting a slot first adds an entry that holds its old
      # value, under the attempts that follow from the capture. By the
      # time the search comes back down to that entry, every one of those
      # attempts has failed, and #run puts the old value back before it
      # makes the attempt below. A search that fails leaves every slot as
      # it started, nil.
      class Search
        attr_reader :text, :size
        # The states and positions tried so far, for the states that
        # depend on no group (#first_time?).
        attr_reader :memo
        # The captures as they are for the attempt being made, for reading
        # a search afterwards: for each group in turn, where its value
        # starts, then where it ends, as byte offsets, or nil.
        attr_reader :slots

        def initialize(text)
          @text = text
          @size = text.bytesize
          # The attempts still to make, the next one last, each as two
          # entries, its position then its state, so that making one
          # allocates nothing. A capture to undo is three: the slot's old
          # value, the slot, then nil where a state would be.
          @to_try = []
          @slots = []
          @memo = Memo.new(@size)
          @tried_with_captures = {}
          @run_ends = {}
          @occurrences = {}
          @units = {}
          @handed_over = {}
          @bytes = nil
          @scanner = nil
        end

        # Where the set's characters fall in the URI (Units), worked out
        # the first time a state asks.
        def units(set)
          @units[set] ||= Units.new(set, @text)
        end

        ##
        # The boundaries, of a stretch from the first to the last, that a
        # state hasn't handed over before as places its value can end, as
        # stretches in order. It notes them as handed over.
        #
        # A state whose value can start in many places finds mostly the
        # same ends from each. Where the captures don't decide whether the
        # rest can match, an end that failed for one start fails for
        # every other, so handing it over again only costs time. One
        # stretch is remembered for each state: a new one that touches it
        # is joined to it, and one that doesn't takes its place, which
        # hands some ends over again but never leaves one out.
        #
        # @param [State] state The state.
        # @param [Integer] first The first boundary.
        # @param [Integer] last The last boundary, before the first if
        #   there are none.
        #
        # @return [Array<Array>] Up to two stretches, each a first and a
        #   last boundary.
        def not_handed_over(state, first, last)
          return [] if first > last
          known = @handed_over[state]
          if known.nil? || first > known[1] + 1 || last < known[0] - 1
            @handed_over[state] = [first, last]
            return [[first, last]]
          end
          fresh = []
          fresh << [first, known[0] - 1] if first < known[0]
          fresh << [known[1] + 1, last] if last > known[1]
          known[0] = first if first < known[0]
          known[1] = last if last > known[1]
          fresh
        end

        # Adds an attempt to make next: the state, at the position, with
        # the captures as they are now.
        def try(state, position)
          @to_try.push(position, state)
        end

        # Adds two attempts, to be made in order. A nil state is left out.
        def try_in_order(first, first_position, second, second_position)
          try(second, second_position) if second
          try(first, first_position) if first
        end

        # Notes where the group's value starts, for the attempts added
        # after this. It's undone before any attempt added earlier is made,
        # as #end_capture and #leave_out are.
        def start_capture(group, position)
          set_slot(group * 2, position)
        end

        # Notes where the group's value ends.
        def end_capture(group, position)
          set_slot(group * 2 + 1, position)
        end

        # Drops where the group's value started, so that it takes no part.
        def leave_out(group)
          set_slot(group * 2, nil)
        end

        # Where the group's value starts, as captured now, or nil.
        def start_of(group)
          @slots[group * 2]
        end

        # Where the group's capture starts and ends now, or nil if it took
        # no part.
        def span(group)
          start = @slots[group * 2]
          finish = @slots[group * 2 + 1]
          [start, finish] if start && finish
        end

        ##
        # Makes the attempts on the list, the last added first, until one
        # reaches the end state at the end of the URI. Each attempt's
        # state adds the attempts that follow from it (State#follow).
        # Coming back down the list to a capture's entry, every attempt
        # above it has failed, so the capture is undone.
        #
        # The same state at the same position always ends the same way,
        # and the first time it failed, or the search would have stopped.
        # So a state that branches is only followed the first time
        # (#first_time?). The others have one way on, which reaches a
        # state that branches within a few steps.
        #
        # With a block, an attempt that gets there is offered to it, with
        # the captures as that attempt has them. If the block turns it
        # down, the search goes on to the next way through, as if the
        # attempt had failed. What the block decides can depend on the
        # captures, which the memo doesn't know about, so a state the
        # search passed on the way to an attempt turned down isn't tried
        # again with other captures: the block sees some of the ways
        # through, in order, not all of them.
        #
        # @param [State] done The end state.
        #
        # @yieldreturn [Boolean] Whether to stop at this attempt.
        #
        # @return [TrueClass, FalseClass]
        #   Whether an attempt got there, and the block took it. If so,
        #   the captures are that attempt's (#captures).
        def run(done)
          to_try = @to_try
          until to_try.empty?
            state = to_try.pop
            if state.nil?
              slot = to_try.pop
              @slots[slot] = to_try.pop
              next
            end
            position = to_try.pop
            next if state.branches? && !first_time?(state, position)
            if state.equal?(done) && position == @size
              return true if !block_given? || yield
              next
            end
            state.follow(self, position)
          end
          false
        end

        ##
        # Whether this is the first time the search reaches the state at
        # the position, with the groups it depends on (State#depends_on)
        # captured in the same places. Other captures don't change whether
        # the rest can match, so they're left out.
        #
        # A state that depends on no group, as most do, is remembered by
        # its position alone, in the memo's row for it (Memo). A state
        # that depends on a group is remembered in a Hash, by its position
        # and where those groups were captured.
        #
        # @param [State] state A state that branches.
        # @param [Integer] position A byte offset.
        def first_time?(state, position)
          if state.depends_on.empty?
            return @memo.first_time?(state.memo_row, position)
          end
          key = [state.index, position] +
            state.depends_on.map { |group| span(group) }
          return false if @tried_with_captures[key]
          @tried_with_captures[key] = true
        end

        # The group's text as captured now, or nil if it took no part.
        def captured(group)
          start = @slots[group * 2]
          finish = @slots[group * 2 + 1]
          @text.byteslice(start, finish - start) if start && finish
        end

        # The text each of the groups captured, or nil for one that took
        # no part, as they are now: for the attempt that reached the end.
        #
        # @param [Integer] groups How many groups the template has.
        #
        # @return [Array<String, nil>]
        def captures(groups)
          Array.new(groups) { |group| captured(group) }
        end

        # Where the longest run of the set starting at the position ends.
        # The URI is read from the start, a run at a time with the set's
        # run pattern, only as far as the questions have reached, and each
        # position read notes where its run ends. So each byte is read
        # once, whatever order the questions come in. The byte after a run
        # is one that isn't in the set, an ASCII byte or a "%" without two
        # hex digits, so the next run starts one byte later.
        def run_end(set, position)
          ends = (@run_ends[set] ||= [])
          while ends.size <= position
            start = ends.size
            scanner.pos = start
            finish = start + scanner.skip(set.run)
            ends.fill(finish, start, finish - start + 1)
          end
          ends[position]
        end

        ##
        # The first place at or after the position where the text occurs,
        # as a byte offset, or nil if it doesn't. The URI is searched
        # forward from the start, one place at a time, only as far as the
        # questions have reached, so each byte is read once per text,
        # whatever order the questions come in.
        #
        # @param [String] piece ASCII text.
        # @param [Integer] position A byte offset.
        #
        # @return [Integer, NilClass]
        def next_occurrence(piece, position)
          found = (@occurrences[piece] ||= Occurrences.new([], 0))
          while found.from && (found.places.empty? || found.places.last < position)
            place = bytes.index(piece, found.from)
            found.places << place if place
            found.from = place && place + 1
          end
          found.places.bsearch { |at| at >= position }
        end

        # How many bytes the pattern matches at the position, or nil if it
        # doesn't match there.
        def skip(pattern, position)
          scanner.pos = position
          scanner.skip(pattern)
        end

        # A scanner on the URI's bytes, so its positions are byte offsets
        # like the search's. Made on first use.
        def scanner
          @scanner ||= StringScanner.new(bytes)
        end

        # The URI as bytes, where String#index counts bytes. Made on first
        # use.
        def bytes
          @bytes ||= @text.b
        end

        # The position, then the end of each character after it, as byte
        # offsets: every place a value starting there can end.
        def character_ends(position)
          ends = [position]
          @text.byteslice(position, @size - position).each_char do |character|
            ends << ends.last + character.bytesize
          end
          ends
        end

        private

        # Sets a slot, after adding the entry that undoes it. This and the
        # methods above it that call it are the only code that knows how
        # the slots are numbered.
        def set_slot(slot, position)
          @to_try.push(@slots[slot], slot, nil)
          @slots[slot] = position
        end
      end
    end
  end
end
