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
    # The values of one expansion by the :machine engine: looking them up,
    # normalizing them, the processor's validate and transform, and the
    # value modifiers (prefix and explode, RFC 6570 section 2.4) and
    # pct-encoding of each varspec. #[] gives a name's value: nil if it's
    # missing or undefined, otherwise a String, Array or Hash, type-checked,
    # and normalized to NFC unless normalize_values is false. A variable used
    # more than once, as in {a}{+a}, is looked up and prepared once. #expand
    # expands it for one varspec, calling the processor each time, once for
    # each occurrence of a variable, as 2.10.0 calls it. Joining a value
    # into its expression (leaders, separators, names) is Machine's.
    #
    # Its class methods normalize mappings and values for both engines.
    # Template calls them directly, except through normalize_value and
    # normalize_keys, which 2.9.2 had as private methods and which
    # subclasses may override.
    #
    # @api private
    class Values
      # Simple, path, label, and query expansion encode every character
      # outside the unreserved set.
      UNRESERVED_ENCODE =
        /[^#{Addressable::URI::CharacterClasses::UNRESERVED}]/
      private_constant :UNRESERVED_ENCODE

      # @param [Hash, #each_pair, #inject, #[]] mapping
      #   The mapping, as Template#expand takes it.
      # @param [Boolean] normalize_values Whether to normalize values.
      # @param [#validate, #transform, nil] processor
      #   The processor passed to expand, if any.
      #
      # @raise [TypeError] If the mapping isn't one Values.normalize_keys
      #   takes.
      def initialize(mapping, normalize_values, processor = nil)
        @mapping = Values.normalize_keys(mapping)
        @normalize_values = normalize_values
        @processor = processor
        @validates = processor.respond_to?(:validate)
        @transforms = processor.respond_to?(:transform)
        @values = {}
      end

      # @param [String] name The variable's name.
      #
      # @raise [TypeError] If the value isn't a String, list or Hash, or a
      #   number, Symbol or boolean.
      #
      # @return [String, Array, Hash, nil] The variable's value.
      def [](name)
        @values.fetch(name) { @values[name] = prepare(@mapping[name]) }
      end

      # Whether the mapping gives the variable, even as nil. partial_expand
      # keeps the expressions of variables that aren't given.
      #
      # @param [String] name The variable's name.
      #
      # @return [TrueClass, FalseClass]
      def key?(name)
        @mapping.key?(name)
      end

      # Whether the mapping gives the variable a defined value: not nil, and
      # not a list or hash with no members once nil members are dropped. As
      # in 2.10.0's partial_expand, the value isn't type-checked or prepared
      # here, so errors come when it's expanded.
      #
      # @param [String] name The variable's name.
      #
      # @return [TrueClass, FalseClass]
      def defined_value?(name)
        key?(name) && !Values.defined_value(@mapping[name]).nil?
      end

      ##
      # Expands a variable's value for one varspec: checks a prefix against
      # a list or hash, validates, then transforms or pct-encodes it with
      # the varspec's modifiers. The variable tags the result for its
      # expression.
      #
      # @param [Machine::Variable] variable
      #   The varspec: its name, prefix, explode, and allows_reserved?.
      #
      # @raise [InvalidTemplateValueError]
      #   If the varspec has a prefix and the value is a list or hash, or
      #   the processor doesn't validate the value.
      #
      # @return [Machine::TaggedValue, nil]
      #   The tagged value, or nil if the variable is undefined.
      def expand(variable)
        name = variable.name
        value = self[name]
        return if value.nil?
        # RFC 6570 section 2.4.1. Template checks this before validating.
        if variable.prefix && (Hash === value || Array === value)
          raise InvalidTemplateValueError,
            "The prefix modifier :#{variable.prefix} can't be applied to " \
            "the list or associative array #{name.inspect}."
        end
        validate(name, value)
        if @transforms
          return transformed(variable, value, transform(name, value))
        end
        encoded(variable, value)
      end

      # Checks a value with the processor's validate method, if it has one.
      #
      # @param [String] name The variable's name.
      # @param [String, Array, Hash] value The variable's value, from #[].
      #
      # @raise [InvalidTemplateValueError] If validate returns false.
      def validate(name, value)
        return unless @validates
        return if @processor.validate(name, value)
        display_value = value.kind_of?(Array) ? value.inspect : value
        raise InvalidTemplateValueError,
          "#{name}=#{display_value} is an invalid template value."
      end

      # @return [TrueClass, FalseClass]
      #   Whether the processor's transform method replaces pct-encoding.
      def transforms?
        @transforms
      end

      # A value transformed by the processor, normalized again unless
      # normalize_values is false. Call it only when #transforms?.
      #
      # @param [String] name The variable's name.
      # @param [String, Array, Hash] value The variable's value, from #[].
      #
      # @return [Object] The transformed value, which isn't pct-encoded.
      def transform(name, value)
        result = @processor.transform(name, value)
        @normalize_values ? Values.normalize_value(result) : result
      end

      private

      # A value pct-encoded for its varspec. Reserved and fragment expansion
      # keep pct-encoded triplets (RFC 6570 section 3.2.3). An exploded
      # hash's members are key=value pairs.
      def encoded(variable, value)
        encode_map =
          variable.allows_reserved? ? RESERVED_ENCODE : UNRESERVED_ENCODE
        explode = variable.explode
        if value.kind_of?(Array)
          members = value.map do |member|
            Addressable::URI.encode_component(member, encode_map)
          end
          variable.tag(explode ? members : members.join(','), nil, true)
        elsif value.kind_of?(Hash)
          separator = explode ? "=" : ","
          pairs = value.map do |key, member|
            "#{Addressable::URI.encode_component(key, encode_map)}" \
              "#{separator}" \
              "#{Addressable::URI.encode_component(member, encode_map)}"
          end
          if explode
            variable.tag(pairs, true, true)
          else
            variable.tag(pairs.join(','), nil, true)
          end
        else
          if variable.prefix
            value = Values.prefix(value, variable.prefix,
              variable.allows_reserved?)
          end
          variable.tag(
            Addressable::URI.encode_component(value, encode_map), nil, false
          )
        end
      end

      # A processor's transform result, which isn't pct-encoded. As in
      # 2.10.0, an array whose first member has an "=" is joined as
      # key=value pairs, and whether it's composite comes from the value
      # before it was transformed.
      def transformed(variable, value, result)
        keypairs = result.is_a?(Array) && result.first.is_a?(String) &&
          result.first.include?("=")
        variable.tag(result, keypairs, Array === value || Hash === value)
      end

      def prepare(value)
        value = Values.defined_value(value)
        return if value.nil?
        # Common primitives where the .to_s output is well-defined
        if Numeric === value || Symbol === value ||
            value == true || value == false
          value = value.to_s
        end
        unless (Hash === value) ||
            value.respond_to?(:to_ary) || value.respond_to?(:to_str)
          raise TypeError,
            "Can't convert #{value.class} into String or Array."
        end
        value = Values.normalize_value(value) if @normalize_values
        value
      end

      ##
      # Picks the mapping to expand with: the one passed, or the block.
      #
      # @param [Object] mapping The mapping argument
      # @param [Proc, nil] block The block
      #
      # @raise [ArgumentError] If both a mapping and a block are given, or
      #   neither.
      #
      # @return [Object] The mapping or the block
      def self.mapping_or_block(mapping, block)
        if block
          unless mapping.equal?(NO_MAPPING) || mapping.nil?
            raise ArgumentError, "Pass a mapping or a block, not both."
          end
          return block
        end
        if mapping.equal?(NO_MAPPING)
          raise ArgumentError, "A mapping or a block is required."
        end
        mapping
      end

      ##
      # A URI fragment can't contain "#" (RFC 3986 section 3.5), so expansion
      # encodes every "#" after the first one, which starts the fragment.
      #
      # @param [String] uri The expanded URI.
      #
      # @return [String] The URI with any later "#" encoded as "%23".
      def self.encode_later_number_signs(uri)
        start = uri.index('#')
        return uri unless start && uri.index('#', start + 1)
        uri[0..start] + uri[(start + 1)..-1].gsub('#', '%23')
      end

      ##
      # Takes the first characters of a value for a prefix modifier. Reserved
      # and fragment expansion count a pct-encoded triplet as one character,
      # so that it isn't split (RFC 6570 section 2.4.1).
      #
      # @param [String] value The value
      # @param [Integer] length The maximum number of characters
      # @param [Boolean] allow_reserved Whether pct-encoded triplets are kept
      #
      # @return [String] The prefix
      def self.prefix(value, length, allow_reserved)
        value = value.to_str
        return value[0...length] unless allow_reserved
        return value.scan(PCT_ENCODED_OR_CHARACTER).first(length).join if
          value.valid_encoding?
        # A regular expression can't scan text that isn't valid UTF-8, but
        # its characters can be read one at a time, each invalid byte as one.
        hex = lambda do |character|
          character && character.bytesize == 1 &&
            HEX_DIGITS.include?(character.getbyte(0))
        end
        characters = value.each_char.to_a
        tokens = []
        until characters.empty? || tokens.size == length
          if characters[0] == "%" && hex.call(characters[1]) &&
              hex.call(characters[2])
            tokens << characters.shift(3).join
          else
            tokens << characters.shift
          end
        end
        tokens.join
      end

      ##
      # Drops the undefined (nil) members of a list or associative array
      # value. RFC 6570 treats a list or associative array with no defined
      # members as undefined, as it does nil.
      #
      # @param [Object] value The mapped value
      #
      # @return [Object, nil] The value without its undefined members, or nil
      #   if the value is undefined
      def self.defined_value(value)
        value = if value.kind_of?(Hash)
          value.reject { |_, member| member.nil? }
        elsif value.respond_to?(:to_ary)
          value.to_ary.reject { |member| member.nil? }
        else
          value
        end
        value unless value == {} || value == []
      end

      ##
      # Takes a set of values, and joins them together based on the
      # operator.
      #
      # @param [Hash, Array, String] value
      #   Normalizes unicode keys and values with String#unicode_normalize (NFC)
      #
      # @return [Hash, Array, String] The normalized values
      def self.normalize_value(value)
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
      def self.utf8_value(value)
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
      def self.normalize_keys(mapping)
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
