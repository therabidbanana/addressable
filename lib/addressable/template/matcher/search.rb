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
      # One place the search can be: a state, a position in the URI, and
      # the captures so far.
      Attempt = Struct.new(:state, :position, :captures) do
        # The attempt at another state and position, with the same
        # captures.
        def move(state, position)
          Attempt.new(state, position, captures)
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
        # state and position. The captures don't change whether the rest
        # can match, so they're left out.
        def first_time?(attempt)
          key = attempt.state.index * (@size + 1) + attempt.position
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
