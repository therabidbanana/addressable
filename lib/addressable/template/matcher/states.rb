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

require "addressable/template/matcher/first_bytes"
require "addressable/template/matcher/search"

module Addressable
  class Template
    class Matcher
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

      # A run of a set's characters. Its subclasses say how many characters
      # it tries taking first.
      class Run < State
        def initialize(index, set)
          super(index)
          @set = set
        end

        def possible_first_bytes
          @set.first_bytes | @next.first_bytes
        end
      end

      # A run as short as possible first: stop here, or take one more
      # character and ask again.
      class LazyRun < Run
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

      # A run as long as possible first: take one more character and ask
      # again, or stop here.
      class GreedyRun < LazyRun
        def follow(attempt, search)
          super.reverse
        end
      end

      # Every character of the set that follows, with no other choice.
      class PossessiveRun < Run
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
          # before any matching, as it does in 2.10.0.
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
    end
  end
end
