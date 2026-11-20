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

require "addressable/template/matching"
require "addressable/template/matcher/first_bytes"
require "addressable/template/matcher/search"

module Addressable
  class Template
    class Matcher
      # A piece of literal text. Raw matches as it is; encoded, if there is
      # one, is the pct-encoded form of a non-ASCII character, whose hex
      # digits match in either case. Either can be nil.
      Unit = Struct.new(:raw, :encoded) do
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
        # for GreedyRun#prepare. Often a match from here can only start with
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

        # ASCII text that every match from here starts with, as written,
        # so that a run before it can find where it's worth stopping with
        # Search#next_occurrence. Nil if there's none, or it isn't known.
        def leading_text
          nil
        end
      end

      # Text that has to come next.
      class Literal < State
        ##
        # The units as one pattern, matched against the URI's bytes
        # (Search#skip): each one's raw text as it is, or its encoded form
        # with ASCII letters in either case. The two forms of a unit start
        # with different bytes, so the pattern never tries both.
        #
        # @param [Array<Unit>] units The units.
        #
        # @return [Regexp]
        def self.pattern(units)
          source = Matching.literal_regexp_source(
            units.map { |unit| [unit.raw, unit.encoded] }
          ).b
          common_patterns[source] || Regexp.new(source, Regexp::NOENCODING)
        end

        # The patterns for the text every operator adds (leaders, joiners,
        # "=", and a "#" that may be written "%23"), compiled once, so that
        # building a matcher only compiles the pattern's own literals. It's
        # made on first use, not as a constant when this file loads:
        # template.rb loads the engines' files before it defines the
        # constants literal_regexp_source uses. Two threads can both make
        # it, which does no harm.
        def self.common_patterns
          @common_patterns ||= (
            %w(/ , . ; & ? = #).map { |text| [[text, nil]] } +
              [[["#", "%23"]]]
          ).map do |units|
            source = Matching.literal_regexp_source(units).b
            [source, Regexp.new(source, Regexp::NOENCODING)]
          end.to_h.freeze
        end

        def initialize(index, units)
          super(index)
          @units = units
          # A literal doesn't depend on what follows it, so its first bytes
          # are known now.
          @text_first_bytes = units.first.first_bytes
          @pattern = Literal.pattern(units)
        end

        def possible_first_bytes
          @text_first_bytes
        end

        # The first unit's text, if it only matches as written. Not if it
        # starts with a hex digit, since that can also be found inside a
        # pct-encoded triplet, where a run can't stop.
        def leading_text
          raw = @units.first.raw
          return nil unless @units.first.encoded.nil? && raw.ascii_only?
          raw unless raw =~ /\A[0-9A-Fa-f]/
        end

        def follow(search, position, captures)
          length = search.skip(@pattern, position)
          search.try(@next, position + length, captures) if length
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

      # A run as long as possible first: take one more character and ask
      # again, or stop here.
      class GreedyRun < Run
        # Asked once the first bytes are known. See State#bytes_after_run
        # and State#leading_text.
        def prepare
          @bytes_after_run_end = @next.bytes_after_run(@set)
          @text_after = @next.leading_text
        end

        def branches?
          true
        end

        def follow(search, position, captures)
          if @bytes_after_run_end
            # What follows can only start inside this run of the set's
            # characters if one of these bytes comes after the run, so
            # otherwise the run only stops at its end.
            run_end = search.run_end(@set, position)
            position = run_end unless @bytes_after_run_end.allow?(search, run_end)
          elsif @text_after
            # What follows starts with this text, so the run can only stop
            # where it occurs. It skips to the next place, or gives up if
            # that isn't in the run.
            run_end = search.run_end(@set, position)
            place = search.next_occurrence(@text_after, position)
            return unless place && place <= run_end
            position = place
          end
          # Stopping here only helps if what follows can start here.
          stop = @next if @next.first_bytes.allow?(search, position)
          after = @set.character_end(search.text, position)
          more = self if after
          search.try_in_order(more, after, stop, position, captures)
        end
      end

      # Goes on only if one of the texts comes next. It takes nothing.
      class FollowedBy < State
        def initialize(index, texts)
          super(index)
          @texts = texts
        end

        def follow(search, position, captures)
          bytes = search.bytes
          return unless @texts.any? do |text|
            bytes.byteslice(position, text.bytesize) == text
          end
          search.try(@next, position, captures)
        end
      end

      # One character of the set.
      class OneCharacter < Run
        def possible_first_bytes
          @set.first_bytes
        end

        # It takes one character, not the whole run.
        def bytes_after_taking_run(_set)
          nil
        end

        def follow(search, position, captures)
          after = @set.character_end(search.text, position)
          search.try(@next, after, captures) if after
        end
      end

      # A run that stops only at a "?" or "#" in it: the first one first,
      # then each later one. Matcher#reserved_run tries it before a
      # greedy run of the same set.
      class DelimiterRun < Run
        def branches?
          true
        end

        # It stops inside its run, so the run before it can't be skipped.
        def bytes_after_taking_run(_set)
          nil
        end

        def follow(search, position, captures)
          run_end = search.run_end(@set, position)
          place = [
            search.next_occurrence("?", position),
            search.next_occurrence("#", position)
          ].compact.min
          return unless place && place < run_end
          stop = @next if @next.first_bytes.allow?(search, place)
          search.try_in_order(stop, place, self, place + 1, captures)
        end
      end

      # Every character of the set that follows, with no other choice.
      class PossessiveRun < Run
        def follow(search, position, captures)
          search.try(@next, search.run_end(@set, position), captures)
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

        def follow(search, position, captures)
          first = @first_state if @first_state.first_bytes.allow?(search, position)
          second = @second_state if @second_state.first_bytes.allow?(search, position)
          search.try_in_order(first, position, second, position, captures)
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

        def follow(search, start, captures)
          rest = search.text.byteslice(start, search.size - start)
          # Without a first choice, the pattern can't match here at all.
          return unless @first_choice =~ rest
          preferred = start + $~[0].bytesize
          ends = search.character_ends(start).sort_by do |finish|
            [(finish - preferred).abs, finish]
          end
          ends.select! do |finish|
            @next.first_bytes.allow?(search, finish) &&
              @whole_value =~ search.text.byteslice(start, finish - start)
          end
          # Handed over last first, so that the first is tried first.
          ends.reverse_each { |finish| search.try(@next, finish, captures) }
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

        def leading_text
          @next.leading_text
        end

        def follow(search, position, captures)
          search.try(@next, position, CaptureList.new(@slot, position, captures))
        end
      end

      # Goes on if the value being captured has taken something, and
      # otherwise leaves the value out: the start of its capture is dropped,
      # and the search goes on where the steps that leave it out go on. The
      # latest capture noted is where the value started.
      class LeaveOutIfEmpty < State
        # The index of the state where a value left out goes on, set once
        # it's added (Matcher#land).
        attr_writer :target

        def link(states)
          super
          @left_out = states[@target]
        end

        def possible_first_bytes
          @next.first_bytes | @left_out.first_bytes
        end

        def follow(search, position, captures)
          if position > captures.position
            search.try(@next, position, captures)
          else
            search.try(@left_out, position, captures.rest)
          end
        end
      end

      # Goes back to an earlier state, the start of a loop, or ahead to a
      # later one (Matcher#jump_ahead).
      class Jump < State
        # The index of the state it goes to, set later for a jump ahead.
        attr_writer :target

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

        def follow(search, position, captures)
          search.try(@next, position, captures)
        end
      end

      # The end of the template. The URI has to end here too.
      class Done < State
        def link(_states)
        end

        def possible_first_bytes
          ONLY_END_OF_URI
        end

        # Nothing follows; Matcher#match checks for the end of the URI.
        def follow(_search, _position, _captures)
        end
      end
    end
  end
end
