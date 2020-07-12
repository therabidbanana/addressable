require "addressable/uri"

module Addressable
  module TemplateMachine
    # Constants used throughout the template code.
    anything =
      Addressable::URI::CharacterClasses::RESERVED +
      Addressable::URI::CharacterClasses::UNRESERVED


    variable_char_class =
      Addressable::URI::CharacterClasses::ALPHA +
      Addressable::URI::CharacterClasses::DIGIT + '_'

    var_char =
      "(?:(?:[#{variable_char_class}]|%[a-fA-F0-9][a-fA-F0-9])+)"
    RESERVED =
      "(?:[#{anything}]|%[a-fA-F0-9][a-fA-F0-9])"
    UNRESERVED =
      "(?:[#{
        Addressable::URI::CharacterClasses::UNRESERVED
      }]|%[a-fA-F0-9][a-fA-F0-9])"

    WITHOUT_RESERVED = /[^#{
      Addressable::URI::CharacterClasses::UNRESERVED
    }]/
    WITH_RESERVED = /[^#{
      Addressable::URI::CharacterClasses::RESERVED +
      Addressable::URI::CharacterClasses::UNRESERVED
    }]/

    variable =
      "(?:#{var_char}(?:\\.?#{var_char})*)"
    varspec =
      "(?:(#{variable})(\\*|:(\\d+))?)"
    VARSPEC = /#{varspec}/
    LEADERS = {
      '?' => '?',
      '/' => '/',
      '#' => '#',
      '.' => '.',
      ';' => ';',
      '&' => '&'
    }.freeze
    JOINERS = {
      '?' => '&',
      '.' => '.',
      ';' => ';',
      '&' => '&',
      '/' => '/'
    }.freeze

    TaggedValue = Struct.new(:name, :value, :keypairs) do
      def to_str(with_name)
        if with_name && !keypairs
          if value.is_a?(Array)
            value.map do |inner|
              "#{name}=#{inner}"
            end
          else
            "#{name}=#{value}"
          end
        else
          if value.is_a?(Array)
            value.map(&:to_str)
          else
            value.to_str
          end
        end
      end
    end

    class Variable
      attr_reader :op, :name, :explode, :prefix

      def initialize(op:, name:, explode: false, prefix: nil)
        @op = op
        @name = name
        @explode = explode
        @prefix = prefix
      end

      ##
      # Takes Array, Hash, or String and runs IDNA unicode normalization.
      #
      # @param [Hash, Array, String] value
      #   Normalizes keys and values with IDNA#unicode_normalize_kc
      #
      # @return [Hash, Array, String] The normalized values
      def normalize_value(value)
        unless value.is_a?(Hash)
          value = value.respond_to?(:to_ary) ? value.to_ary : value.to_str
        end

        # Handle unicode normalization
        if value.kind_of?(Array)
          value.map! { |val| Addressable::IDNA.unicode_normalize_kc(val) }
        elsif value.kind_of?(Hash)
          value = value.inject({}) { |acc, (k, v)|
            acc[Addressable::IDNA.unicode_normalize_kc(k)] =
              Addressable::IDNA.unicode_normalize_kc(v)
            acc
          }
        else
          value = Addressable::IDNA.unicode_normalize_kc(value)
        end
        value
      end

      ##
      # Takes Array, Hash, or String, normalizes and prepares a tagged value for
      # template expansion
      #
      # @param [Hash, Array, String] value
      #   Value to expand for this variable
      # @param [#validate, #transform] processor
      #   An optional processor object may be supplied.
      # @param [Boolean] normalize_values
      #   Optional flag to enable/disable unicode normalization. Default: true
      #
      # @return [Hash, Array, String] The normalized values
      def expand_with(value, processor: nil, normalize_values: true)
        unless value == nil || value == {}
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

          value = normalize_value(value) if normalize_values

          if processor == nil || !processor.respond_to?(:transform)
            # Handle percent escaping
            if @op.allows_reserved?
              encode_map = WITH_RESERVED
            else
              encode_map = WITHOUT_RESERVED
            end
            if value.kind_of?(Array)
              transformed_value = value.map do |val|
                if @prefix
                  Addressable::URI.encode_component(val[0...@prefix], encode_map)
                else
                  Addressable::URI.encode_component(val, encode_map)
                end
              end
              unless self.explode
                transformed_value = transformed_value.join(',')
              end
            elsif value.kind_of?(Hash)
              transformed_value = value.map do |key, val|
                if self.explode
                  "#{
                    Addressable::URI.encode_component( key, encode_map)
                  }=#{
                    Addressable::URI.encode_component( val, encode_map)
                  }"
                else
                  "#{
                    Addressable::URI.encode_component( key, encode_map)
                  },#{
                    Addressable::URI.encode_component( val, encode_map)
                  }"
                end
              end
              if self.explode
                keypairs = true
              else
                transformed_value = transformed_value.join(',')
              end
            else
              if @prefix
                transformed_value = Addressable::URI.encode_component(
                  value[0...@prefix], encode_map)
              else
                transformed_value = Addressable::URI.encode_component(
                  value, encode_map)
              end
            end
          end
          TaggedValue.new(name, transformed_value, keypairs)
        end
      end
    end

    class Expression
      def self.allows_reserved?
        false
      end

      def self.prefer_keypairs?
        false
      end

      def self.concat(mapping, variables)
        list = variables.map do |variable|
          variable.expand_with(mapping[variable.name])
        end
        unless list.empty?
          joined_values(list.compact)
        end
      end

      def self.leader; ""; end
      def self.joiner; ","; end

      def self.joined_values(list)
        leader + list.flat_map{|val|
          val.to_str(prefer_keypairs?)
        }.join(joiner)
      end

      def self.extract_values(scanner, list)
        raise 'unimplemented'
      end

      def self.normalize_value(value)
      end
    end

    class OpPlain < Expression
      def self.leader; ""; end
      def self.joiner; ","; end
    end

    class OpPath < Expression
      def self.leader; "/"; end
      def self.joiner; "/"; end
      def self.extract_values(scanner, list)
        matches = {}
        list.each do |var|
          if var.explode
          else
            scanned = scanner.scan(/\/(#{UNRESERVED}*)/)
            matches[var.name] = scanner[1]
          end
        end
        matches
      end
    end

    class OpDot < Expression
      def self.leader; "."; end
      def self.joiner; "."; end
    end

    class OpQuery < Expression
      def self.leader; "?"; end
      def self.joiner; "&"; end
      def self.prefer_keypairs?; true; end
      def self.extract_values(scanner, list)
        matches = {}
        scan_state = :start
        list.each do |var|
          scanned = scanner.getch
          if scan_state == :start
            return unless scanned == "?"
            scanned = scanner.scan(/(#{var.name})=(#{UNRESERVED}*)/)
            if scanned
              matches[var.name] = scanner[2]
            end
            scan_state = :next
          else
            return unless scanned == "&"
            scanned = scanner.scan(/(#{var.name})=(#{UNRESERVED}*)/)
            if scanned
              matches[var.name] = scanner[2]
            end
          end
        end
        matches
      end
    end
  end
end
