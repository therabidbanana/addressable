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
      # A row is a String used as a list of small numbers, one byte for
      # each position in the URI: NOT_TRIED until the position is noted,
      # and TRIED after. It's made the first time the row is used. That's
      # one byte for each position, for each state reached. An Array of
      # true and nil takes eight, which is no less than one Hash of every
      # state and position tried (about 35 bytes each) where a state is
      # tried at a few positions in each stretch. #positions and #to_s
      # list what's noted, for specs and for reading a search that went
      # wrong.
      #
      # @api private
      class Memo
        NOT_TRIED = 0
        TRIED = 1
        # One position not yet tried, to make rows of.
        BLANK = NOT_TRIED.chr.b.freeze

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
        #
        # @raise [IndexError] For a position past the end of the URI.
        def first_time?(row, position)
          tried = (@rows[row] ||= BLANK * (@size + 1))
          return false if tried.getbyte(position) == TRIED
          tried.setbyte(position, TRIED)
          true
        end

        # The positions noted in the row, in order.
        def positions(row)
          tried = @rows[row]
          return [] unless tried
          (0..@size).select { |position| tried.getbyte(position) == TRIED }
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
