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
      # The bytes a match from a state can start with, and whether it can
      # be at the end of the URI without taking anything. It may include
      # bytes that can't start a match, but never leaves one out, so
      # skipping a state whose first bytes don't include the next byte
      # never changes the result. Kept as one Integer, with bit n for byte
      # n, so that joining two is one "|".
      class FirstBytes
        END_OF_URI = 256

        attr_reader :mask

        def initialize(mask = 0)
          @mask = mask
        end

        def self.bytes(*bytes)
          new(bytes.inject(0) { |mask, byte| mask | (1 << byte) })
        end

        # Both sets' bytes. One that already has them all is reused, so
        # working the sets out again changes nothing and makes nothing new.
        def |(other)
          joined = mask | other.mask
          if joined == mask
            self
          elsif joined == other.mask
            other
          else
            FirstBytes.new(joined)
          end
        end

        def ==(other)
          other.is_a?(FirstBytes) && mask == other.mask
        end

        # Whether a match can start at the position: with the byte there,
        # or at the end of the URI.
        def allow?(search, position)
          byte = position < search.size ? search.text.getbyte(position) :
            END_OF_URI
          mask[byte] == 1
        end

        def disjoint?(other)
          (mask & other.mask).zero?
        end

        # The bytes, for Matcher#to_s: the visible ASCII characters as they
        # are, then whether there are others, and the end of the URI.
        def to_s
          visible = (33..126).select { |byte| mask[byte] == 1 }
          others = (0...END_OF_URI).any? do |byte|
            mask[byte] == 1 && !(33..126).cover?(byte)
          end
          parts = []
          parts << visible.map(&:chr).join.inspect unless visible.empty?
          parts << "other bytes" if others
          parts << "the end" if mask[END_OF_URI] == 1
          parts.empty? ? "nothing" : parts.join(", ")
        end
      end

      # Every state's first bytes before Matcher#finish works them out.
      NOTHING = FirstBytes.new
      # A processor's pattern can start with anything, or match nothing.
      ANYTHING = FirstBytes.new((1 << (FirstBytes::END_OF_URI + 1)) - 1)
      # Where the template ends: nothing but the end of the URI can follow.
      ONLY_END_OF_URI = FirstBytes.bytes(FirstBytes::END_OF_URI)
    end
  end
end
