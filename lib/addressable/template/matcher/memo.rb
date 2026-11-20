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
      # The places one search has tried: for each row, a set of positions
      # in the URI. The search gives each state that branches a row
      # (State#memo_row), and asks #first_time? before it follows one.
      #
      # A row is kept as one bit for each position, in a String of bytes
      # made the first time the row is used: an eighth of the URI's length
      # for each state reached, where a Hash of positions takes about 35
      # bytes for each one tried. Nothing outside this class reads the
      # bits: #positions and #to_s list what's noted, for specs and for
      # reading a search that went wrong.
      #
      # @api private
      class Memo
        # A zero byte, to make rows of.
        NO_BYTE = "\0".b.freeze

        # @param [Integer] size
        #   The URI's length in bytes. Positions run from 0 to the size,
        #   which is the end of the URI.
        def initialize(size)
          @size = size
          @rows = []
        end

        ##
        # Notes the position in the row, and says whether it was new.
        #
        # @param [Integer] row The row, from 0.
        # @param [Integer] position A byte offset, from 0 to the size.
        #
        # @return [TrueClass, FalseClass]
        #   Whether this is the first time the position is noted in the row.
        def first_time?(row, position)
          unless position >= 0 && position <= @size
            raise IndexError, "position #{position} outside 0..#{@size}"
          end
          bytes = (@rows[row] ||= NO_BYTE * ((@size >> 3) + 1))
          byte = bytes.getbyte(position >> 3)
          bit = 1 << (position & 7)
          return false if byte & bit != 0
          bytes.setbyte(position >> 3, byte | bit)
          true
        end

        # The positions noted in the row, in order.
        def positions(row)
          bytes = @rows[row]
          return [] unless bytes
          (0..@size).select do |position|
            bytes.getbyte(position >> 3) & (1 << (position & 7)) != 0
          end
        end

        # The rows used, a row to a line, each with its positions.
        def to_s
          used = @rows.each_index.select { |row| @rows[row] }
          used.map { |row| "#{row}: #{positions(row).join(' ')}" }.join("\n")
        end
      end
    end
  end
end
