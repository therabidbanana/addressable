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
    # Normalizes mappings and values for both engines. Template's private
    # methods of the same names call these, and so does the :machine
    # engine.
    #
    # @api private
    module Values
      module_function

      ##
      # Takes a set of values, and joins them together based on the
      # operator.
      #
      # @param [Hash, Array, String] value
      #   Normalizes unicode keys and values with String#unicode_normalize (NFC)
      #
      # @return [Hash, Array, String] The normalized values
      def normalize_value(value)
        # Handle unicode normalization
        if value.respond_to?(:to_ary)
          value = value.to_ary.map { |val| normalize_value(val) }
        elsif value.kind_of?(Hash)
          value = value.inject({}) { |acc, (k, v)|
            acc[normalize_value(k)] = normalize_value(v)
            acc
          }
        else
          value = value.to_s if !value.kind_of?(String)
          value = utf8_value(value)
          # Text that isn't valid UTF-8 can't be normalized; its bytes are
          # pct-encoded as they are.
          value = value.unicode_normalize(:nfc) if value.valid_encoding?
        end
        value
      end

      ##
      # A value as UTF-8. RFC 6570 section 3.2.1 transcodes a value in another
      # character encoding to UTF-8. A binary or US-ASCII value, or one that
      # isn't valid in its own encoding, is read as UTF-8 as it is.
      #
      # @param [String] value The value.
      #
      # @return [String] The value in UTF-8, which may not be valid UTF-8.
      def utf8_value(value)
        encoding = value.encoding
        return value if encoding == Encoding::UTF_8
        if encoding != Encoding::BINARY && encoding != Encoding::US_ASCII &&
            value.valid_encoding?
          begin
            return value.encode(Encoding::UTF_8)
          rescue EncodingError
            # A character with no Unicode equivalent keeps its bytes.
          end
        end
        value.dup.force_encoding(Encoding::UTF_8)
      end

      ##
      # Generates a hash with string keys, or a lookup for a mapping that isn't
      # enumerable
      #
      # @param [Hash, #each_pair, #inject, #[]] mapping A mapping to normalize
      #
      # @return [Hash, MappingLookup]
      #   A hash with stringified keys, or a lookup
      def normalize_keys(mapping)
        if mapping.respond_to?(:each_pair)
          pairs = mapping.to_enum(:each_pair)
        elsif mapping.respond_to?(:inject)
          pairs = mapping
        elsif mapping.respond_to?(:[]) && !mapping.respond_to?(:to_str) &&
            !(Symbol === mapping) && !(Numeric === mapping)
          return MappingLookup.new(mapping)
        else
          raise TypeError, "Can't convert #{mapping.class} into a mapping."
        end
        return pairs.inject({}) do |accu, pair|
          name, value = pair
          if Symbol === name
            name = name.to_s
          elsif name.respond_to?(:to_str)
            name = name.to_str
          else
            raise TypeError,
              "Can't convert #{name.class} into String."
          end
          accu[name] = value
          accu
        end
      end
    end
  end
end
