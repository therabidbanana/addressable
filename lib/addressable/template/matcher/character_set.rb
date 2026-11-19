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

require "addressable/uri"
require "addressable/template/matcher/first_bytes"

module Addressable
  class Template
    class Matcher
      # The characters a variable's value can contain, as the :regexp
      # engine's classes have them: some ASCII characters, any pct-encoded
      # triplet, and any non-ASCII character.
      class CharacterSet
        # The bytes a character of the set can start with: an ASCII
        # character in the set, "%", or any non-ASCII byte.
        attr_reader :first_bytes
        # A run of the set's characters, for StringScanner#skip on the
        # URI's bytes (Search#run_end). It's possessive, so it takes every
        # character it can and never gives one back: it reads each byte
        # once, on every runtime.
        attr_reader :run

        def initialize(characters)
          pattern = Regexp.new("[#{characters}]")
          @ascii = Array.new(128) { |byte| pattern =~ byte.chr ? true : false }
          ascii = (0...128).select { |byte| @ascii[byte] }
          @first_bytes = FirstBytes.bytes(37, *ascii, *(0x80..0xFF))
          @run = Regexp.new(
            "(?:[#{characters}]|%[0-9A-Fa-f]{2}|[\\x80-\\xFF])*+",
            Regexp::NOENCODING
          )
        end

        ##
        # Where the character at the position ends, if it's in the set.
        #
        # @param [String] text The URI, valid UTF-8.
        # @param [Integer] position A byte offset.
        #
        # @return [Integer, NilClass] The byte offset after the character.
        def character_end(text, position)
          byte = text.getbyte(position)
          if byte.nil?
            nil
          elsif byte >= 0xF0
            position + 4
          elsif byte >= 0xE0
            position + 3
          elsif byte >= 0x80
            position + 2
          elsif @ascii[byte]
            position + 1
          elsif byte == 37 && hex?(text.getbyte(position + 1)) &&
              hex?(text.getbyte(position + 2))
            position + 3
          end
        end

        private

        def hex?(byte)
          HEX_DIGITS.include?(byte)
        end
      end

      unreserved = Addressable::URI::CharacterClasses::UNRESERVED
      reserved = Addressable::URI::CharacterClasses::RESERVED + unreserved
      SETS = {
        unreserved: CharacterSet.new(unreserved),
        # A ; member: name and value characters and "=", in any order.
        unreserved_or_equals: CharacterSet.new(unreserved + "="),
        # A label's value, which can't contain "." unless it's delimited.
        unreserved_no_dot: CharacterSet.new(unreserved.gsub("\\.", "")),
        reserved: CharacterSet.new(reserved),
        # A + or # value before the last, which ends at a comma.
        reserved_no_comma: CharacterSet.new(reserved.delete(","))
      }.freeze
    end
  end
end
