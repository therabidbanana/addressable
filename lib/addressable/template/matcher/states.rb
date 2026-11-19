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
          @bytes_after_run = {}
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

        # Whether the state can go on more than one way. The search only
        # remembers where it tried these (see Matcher#match).
        def branches?
          false
        end

        # The first bytes, from the states it moves on to. Loops make a
        # state depend on itself, so Matcher#finish asks again until no
        # answer changes.
        def possible_first_bytes
          @next.first_bytes
        end

        ##
        # Where a run of the set just before this state is worth stopping,
        # for LazyRun#prepare. Often a match from here can only start with
        # one of the set's characters by taking the rest of their run: in
        # {?a,b}, b's name takes a's whole value, then needs "=". Then the
        # run before can only stop inside a run of its characters if the
        # run is followed by one of the bytes this returns. It's NOTHING if
        # no match from here starts with one of the set's characters, and
        # nil if one can without taking the whole run, or that isn't known.
        # Asked once the first bytes are known.
        #
        # @param [CharacterSet] set The run's set.
        #
        # @return [FirstBytes, NilClass]
        def bytes_after_run(set)
          unless @bytes_after_run.key?(set)
            @bytes_after_run[set] =
              if set.first_bytes.disjoint?(first_bytes)
                NOTHING
              else
                bytes_after_taking_run(set)
              end
          end
          @bytes_after_run[set]
        end

        # bytes_after_run for a state that can start with one of the set's
        # characters. Unknown, unless the state's class knows.
        def bytes_after_taking_run(_set)
          nil
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

        # A run of the same set that always takes the rest of the run is
        # followed by what follows it.
        def bytes_after_taking_run(set)
          @next.first_bytes if set.equal?(@set) && takes_whole_run?
        end

        # Whether the run always takes every character of the set that
        # follows: it can't stop sooner when what follows it can't start
        # with one of them.
        def takes_whole_run?
          @set.first_bytes.disjoint?(@next.first_bytes)
        end
      end

      # A run as short as possible first: stop here, or take one more
      # character and ask again.
      class LazyRun < Run
        # Asked once the first bytes are known. See State#bytes_after_run.
        def prepare
          @bytes_after_run_end = @next.bytes_after_run(@set)
        end

        def branches?
          true
        end

        def follow(attempt, search)
          position = attempt.position
          if @bytes_after_run_end
            # What follows can only start inside this run of the set's
            # characters if one of these bytes comes after the run, so
            # otherwise the run only stops at its end.
            run_end = search.run_end(@set, position)
            position = run_end unless @bytes_after_run_end.allow?(search, run_end)
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
        def takes_whole_run?
          true
        end

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

        def branches?
          true
        end

        # Either way on can be taken, so both have to know.
        def bytes_after_taking_run(set)
          first = @first_state.bytes_after_run(set)
          second = @second_state.bytes_after_run(set)
          first | second if first && second
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

      # A value matched by a processor's pattern: a regexp the caller gives.
      # The pattern's own first choice is tried first, then the other ends
      # nearest it, shorter first where two are as near: a greedy pattern
      # gives back characters and a lazy one takes more, as they would in
      # a regexp. An end is tried if what follows can start there and the
      # pattern matches the whole value up to it.
      #
      # This is where the machine differs from Template, which puts the
      # pattern in its regexp and tries every end in the order the pattern
      # prefers. Where a URI can be split more than one way, the split can
      # differ, and the pattern only sees the rest of the URI, then only the
      # value, so a lookbehind stops at the value's start and a lookahead at
      # its end. In return, nothing backtracks across the template: each
      # check reads one value, and only the pattern itself can backtrack,
      # however it was written.
      class ProcessorPattern < State
        def initialize(index, source)
          super(index)
          # Compiled now, so a pattern that isn't valid raises RegexpError
          # before any matching, as it does in :regexp.
          @first_choice = Regexp.new("\\A(?:#{source})")
          @whole_value = Regexp.new("\\A(?:#{source})\\z")
        end

        def possible_first_bytes
          ANYTHING
        end

        def branches?
          true
        end

        def follow(attempt, search)
          start = attempt.position
          rest = search.text.byteslice(start, search.size - start)
          # Without a first choice, the pattern can't match here at all.
          return [] unless @first_choice =~ rest
          preferred = start + $~[0].bytesize
          ends = search.character_ends(start).sort_by do |finish|
            [(finish - preferred).abs, finish]
          end
          attempts = []
          ends.each do |finish|
            next unless @next.first_bytes.allow?(search, finish)
            value = search.text.byteslice(start, finish - start)
            attempts << attempt.move(@next, finish) if @whole_value =~ value
          end
          attempts
        end
      end

      # Notes the position, as the start or the end of a variable's value.
      class Capture < State
        def initialize(index, slot)
          super(index)
          @slot = slot
        end

        # It takes nothing, so what follows it decides.
        def bytes_after_taking_run(set)
          @next.bytes_after_run(set)
        end

        def follow(attempt, _search)
          captures = CaptureList.new(@slot, attempt.position, attempt.captures)
          [Attempt.new(@next, attempt.position, captures)]
        end
      end

      # Goes back to an earlier state, the start of a loop.
      class Jump < State
        def initialize(index, target)
          super(index)
          @target = target
        end

        def link(states)
          @next = states[@target]
        end

        # It takes nothing, so the state it goes back to decides.
        def bytes_after_taking_run(set)
          @next.bytes_after_run(set)
        end

        def follow(attempt, _search)
          [attempt.move(@next, attempt.position)]
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
