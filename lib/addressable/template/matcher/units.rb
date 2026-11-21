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

module Addressable
  class Template
    class Matcher
      ##
      # Where the characters of one set fall in a URI, so that a value with
      # a prefix modifier (CappedRun) can find how far its length reaches
      # from any start without walking there.
      #
      # The URI's text is cut into units: a character of the set as it is,
      # or a pct-encoded triplet. Each place a unit starts or ends is a
      # boundary, numbered in order through the URI. A byte that isn't in
      # the set ends a run of units, and the next run starts after it.
      #
      # A prefix's length counts decoded characters, since expansion cuts
      # the value before it pct-encodes it: a character as it is, or the
      # triplets of one UTF-8 character, is one. So is a triplet that isn't
      # part of such a character, as + and # expansion count it. Each unit
      # has a weight, 1 if it starts a decoded character and 0 if it's a
      # triplet that carries one on, and the count of a stretch of units
      # is the sum of their weights. A value that starts on a triplet that
      # would carry a character on has nothing to carry on, so that
      # triplet, and each like it right after, counts 1 for that value.
      #
      # @api private
      class Units
        # @param [CharacterSet] set The set.
        # @param [String] text The URI, valid UTF-8.
        def initialize(set, text)
          @set = set
          @text = text
          # The byte offset of each boundary, in order.
          @positions = []
          # For a byte offset that's a boundary, its number.
          @boundary_at = []
          # For each boundary, the weights of its run's units up to it.
          @counts = []
          # For each boundary, how many units that carry a character on
          # come right after it.
          @carried_on = []
          # For each boundary, the last boundary of its run.
          @run_ends = []
          position = 0
          size = text.bytesize
          while position <= size
            # The byte after a run isn't in the set, so it's one ASCII
            # byte, and the next run starts right after it.
            position = add_run(position) + 1
          end
        end

        # The byte offset of a boundary.
        def position(boundary)
          @positions[boundary]
        end

        ##
        # Every place a value that starts at the position can end, taking
        # at most a number of decoded characters.
        #
        # A value can start inside a triplet, after a literal that took
        # its "%", where there's no boundary: the hex digits left are
        # units of their own for it. Those places come first, as byte
        # offsets, and then a stretch of boundaries, which is empty if its
        # first is after its last.
        #
        # @param [Integer] position A byte offset.
        # @param [Integer] length The most decoded characters.
        #
        # @return [Array]
        #   The byte offsets before the first boundary, in order, then the
        #   first and the last boundary.
        def reach(position, length)
          before = []
          until (boundary = @boundary_at[position])
            before << position
            after = @set.character_end(@text, position)
            return [before, 0, -1] if after.nil? || length.zero?
            length -= 1
            position = after
          end
          [before, boundary, last_within(boundary, length)]
        end

        private

        # Adds the run of units that starts at the position, which may be
        # empty, and gives where it ends.
        def add_run(position)
          first = @positions.size
          weights = []
          count = 0
          # How many more triplets belong to the UTF-8 character begun.
          continuing = 0
          add_boundary(position, count)
          while (after = @set.character_end(@text, position))
            octet = triplet_octet(position, after)
            if octet && continuing > 0 && octet >= 0x80 && octet < 0xC0
              continuing -= 1
              weights << 0
            else
              count += 1
              continuing = octet ? continuation_octets(octet) : 0
              weights << 1
            end
            position = after
            add_boundary(position, count)
          end
          last = @positions.size - 1
          @carried_on[last] = 0
          (last - 1).downto(first) do |boundary|
            @carried_on[boundary] =
              weights[boundary - first].zero? ? @carried_on[boundary + 1] + 1 : 0
          end
          (first..last).each { |boundary| @run_ends[boundary] = last }
          position
        end

        def add_boundary(position, count)
          @boundary_at[position] = @positions.size
          @positions << position
          @counts << count
        end

        # The last boundary a value that starts at one can reach within a
        # number of decoded characters: in its run, and found by halving,
        # since the count only grows along it.
        def last_within(first, length)
          last = @run_ends[first]
          carried_on = @carried_on[first]
          start = @counts[first]
          past = ((first + 1)..last).bsearch do |boundary|
            units = boundary - first
            @counts[boundary] - start +
              (units < carried_on ? units : carried_on) > length
          end
          past ? past - 1 : last
        end

        # The octet a pct-encoded triplet at the position stands for, or
        # nil if the character there is written as it is.
        def triplet_octet(position, after)
          return nil unless @text.getbyte(position) == 37 &&
            after == position + 3
          @text.byteslice(position + 1, 2).hex
        end

        # How many more octets a UTF-8 character that starts with this one
        # has.
        def continuation_octets(octet)
          if octet >= 0xF0
            3
          elsif octet >= 0xE0
            2
          elsif octet >= 0xC0
            1
          else
            0
          end
        end
      end
    end
  end
end
