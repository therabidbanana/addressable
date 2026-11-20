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

module Addressable
  class Template
    class Matcher
      # The captures, as a list from the latest back to the first, so an
      # attempt adds one without copying the others.
      CaptureList = Struct.new(:slot, :position, :rest)

      # Where a piece of literal text occurs in the URI: the places found
      # so far, in order, and where to look for the next one, or nil once
      # there are no more.
      Occurrences = Struct.new(:places, :from)

      # What the search keeps for one URI: the text, the attempts to make
      # and those tried, where runs of each set end, and where literal text
      # occurs.
      class Search
        attr_reader :text, :size
        # The states and positions tried so far, for the states that
        # depend on no group (#first_time?).
        attr_reader :memo
        # The attempts still to make, the next one last. Each is a state, a
        # position in the URI and the captures so far, kept as three
        # entries rather than an object of its own, so that making one
        # allocates nothing. Matcher#match takes them off.
        attr_reader :to_try

        def initialize(text)
          @text = text
          @size = text.bytesize
          @to_try = []
          @memo = Memo.new(@size)
          @tried_with_captures = {}
          @run_ends = {}
          @occurrences = {}
          @bytes = nil
          @scanner = nil
        end

        # Adds an attempt to make next: the state, at the position, with
        # the captures so far.
        def try(state, position, captures)
          @to_try.push(captures, position, state)
        end

        # Adds two attempts with the same captures, to be made in order.
        # A nil state is left out.
        def try_in_order(first, first_position, second, second_position,
          captures)
          try(second, second_position, captures) if second
          try(first, first_position, captures) if first
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
        # @param [CaptureList, nil] captures The captures so far.
        def first_time?(state, position, captures)
          if state.depends_on.empty?
            return @memo.first_time?(state.memo_row, position)
          end
          key = [state.index, position] +
            state.depends_on.map { |group| span(group, captures) }
          return false if @tried_with_captures[key]
          @tried_with_captures[key] = true
        end

        # The group's text, from the latest start and end noted for it, or
        # nil if it took no part.
        def captured(group, captures)
          start, finish = span(group, captures)
          @text.byteslice(start, finish - start) if finish
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

        # Where the group's latest capture starts and ends, or nil if it
        # took no part.
        def span(group, captures)
          start = finish = nil
          list = captures
          while list && !(start && finish)
            if list.slot == group * 2
              start ||= list.position
            elsif list.slot == group * 2 + 1
              finish ||= list.position
            end
            list = list.rest
          end
          [start, finish] if start && finish
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
      end

      # A match's captures: the text each group took, for
      # Machine::Slots#mapping. The slots are byte offsets.
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
      end
    end
  end
end
