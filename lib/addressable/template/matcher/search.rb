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
        # The attempts still to make, the next one last. Each is a state, a
        # position in the URI and the captures so far, kept as three
        # entries rather than an object of its own, so that making one
        # allocates nothing. Matcher#match takes them off.
        attr_reader :to_try

        def initialize(text)
          @text = text
          @size = text.bytesize
          @to_try = []
          @tried = {}
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

        # Whether this is the first time the search reaches the state at
        # the position. The captures don't change whether the rest can
        # match, so they're left out.
        def first_time?(state, position)
          key = state.index * (@size + 1) + position
          return false if @tried[key]
          @tried[key] = true
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
    end
  end
end
