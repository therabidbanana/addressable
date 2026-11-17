require "addressable/uri"
require "addressable/template/values"

# Written as Addressable::Template, not nested, so the body keeps its
# indentation from before the move.
class Addressable::Template
  # The :machine engine's nodes: a Variable for each varspec, and an
  # Expression subclass for each operator. Lexer builds them and
  # ParsedTemplate walks them.
  #
  # @api private
  module Machine
    # Constants used throughout the template code.
    anything =
      Addressable::URI::CharacterClasses::RESERVED +
      Addressable::URI::CharacterClasses::UNRESERVED


    variable_char_class =
      Addressable::URI::CharacterClasses::ALPHA +
      Addressable::URI::CharacterClasses::DIGIT + '_'

    # Atomic, as in Template, so a long name can't backtrack.
    var_char =
      "(?>(?:[#{variable_char_class}]|%[a-fA-F0-9][a-fA-F0-9])+)"
    RESERVED =
      "(?:[#{anything}]|%[a-fA-F0-9][a-fA-F0-9])"

    UNRESERVED_SCAN =
      "((?:[#{
        Addressable::URI::CharacterClasses::UNRESERVED
      }]|%[a-fA-F0-9][a-fA-F0-9]|,)*)"

    UNRESERVED_SET =
      "(?:[#{
        Addressable::URI::CharacterClasses::UNRESERVED
      }]|%[a-fA-F0-9][a-fA-F0-9])"

    variable =
      "(?:#{var_char}(?:\\.?#{var_char})*)"
    varspec =
      "(?:(#{variable})(\\*|:([1-9]\\d{0,3}))?)"
    VARSPEC = /#{varspec}/

    # A token that isn't valid: the error Template raises for it, which
    # ParsedTemplate raises from the first operation that needs a valid
    # pattern, and the names Template#variables still finds in it.
    Invalid = Struct.new(:error_class, :message, :names)
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

    # A variable's expanded value, for its expression to join. keypairs
    # says an array holds key=value pairs; composite says the value was a
    # list or associative array before it was expanded, so it isn't empty
    # even when its members join to an empty string (RFC 6570 section
    # 3.2.7).
    class TaggedValue < Struct.new(:name, :value, :keypairs, :composite)
      # The value, or its members, for Expression#joined_values to join. A
      # processor's transform result can hold anything, so members are left
      # for Array#join to flatten and convert, as Template's join_values
      # leaves them.
      def to_str
        if value.is_a?(Array)
          value
        else
          value.to_s
        end
      end
    end

    # Path-style parameters (;). An empty member or pair value gets no "="
    # (RFC 6570 appendix A), but a list or associative array whose members
    # join to an empty string does, as in Template's join_values.
    class PathParamTaggedValue < TaggedValue
      def to_str
        if keypairs
          # Values are pct-encoded, so a pair that ends in "=" is empty.
          value.map { |pair| pair.end_with?("=") ? pair[0...-1] : pair }
        elsif value.is_a?(Array)
          value.map { |inner| inner == "" ? name : "#{name}=#{inner}" }
        elsif (value && value != "") || composite
          "#{name}=#{value}"
        else
          name
        end
      end
    end

    class NamedTaggedValue < TaggedValue
      def to_str
        if !keypairs
          if value.is_a?(Array)
            value.map do |inner|
              "#{name}=#{inner}"
            end
          else
            "#{name}=#{value}"
          end
        else
          super
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

      def unencode(value)
        if value.is_a?(Hash)
          value = value.inject({}){|acc, (k, v)|
            acc[Addressable::URI.unencode_component(k)] =
              Addressable::URI.unencode_component(v)
            acc
          }
        elsif value.is_a?(Array)
          value = value.map{|v| Addressable::URI.unencode_component(v) }
        else
          value = Addressable::URI.unencode_component(value)
        end
      end


      # Whether its operator keeps reserved characters and pct-encoded
      # triplets (+ and #). Values#expand encodes by this.
      def allows_reserved?
        @op.allows_reserved?
      end

      ##
      # Tags an expanded value for joining into its expression, as its
      # operator joins values.
      #
      # @param [String, Array] value The value from Values#expand.
      # @param [TrueClass, FalseClass, nil] keypairs
      #   Whether an array holds key=value pairs.
      # @param [TrueClass, FalseClass] composite
      #   Whether the value was a list or associative array before it was
      #   expanded.
      #
      # @return [TaggedValue] The tagged value.
      def tag(value, keypairs, composite)
        op.tagged_value.new(name, value, keypairs, composite)
      end
    end

    class Expression
      attr_reader :variables
      def initialize(variables)
        @variables = variables
      end

      def self.allows_reserved?
        false
      end

      def self.tagged_value
        TaggedValue
      end

      def tagged_value
        self.class.tagged_value
      end

      # @param [Values] values The template's values.
      def join_expansions(values)
        list = variables.map do |variable|
          values.expand(variable)
        end
        list.compact!
        unless list.empty?
          joined_values(list)
        end
      end

      def self.leader; ""; end
      def self.joiner; ","; end

      def joined_values(list)
        self.class.leader + list.flat_map{|val|
          val.to_str
        }.join(self.class.joiner)
      end

      def extract_values(scanner, matches)
        scanner = StringScanner.new(scanner) unless scanner.is_a?(StringScanner)
        scanned = scanner.scan(/#{Regexp.escape(self.class.leader)}/)
        if scanned
          variables.each do |var|
            scanned = nil
            # TODO: Fixme
            # Explode seems to work better than other conditions.
            # Need to break up some of this nasty logic.
            if var.explode or true
              scanning_set = /((?:#{UNRESERVED_SET}|#{self.class.joiner}|,|=)*)/
              scanned = scanner.scan(scanning_set)
              if scanned
                if scanner[1] =~ /#{self.class.joiner}/
                  results = scanner[1].split(self.class.joiner)
                else
                  results = scanner[1].split(',')
                end
                results.map do |result|
                  vals = result.split('=')
                  if vals.size == 1
                    case matches[var.name]
                    when Array
                      matches[var.name] << var.unencode(vals.first)
                    when String
                      matches[var.name] = [matches[var.name], var.unencode(vals.first)]
                    when Hash
                      matches[var.name][var.unencode(vals.first)] = ""
                    else
                      matches[var.name] = var.unencode(vals.first)
                    end
                  else
                    matches[var.name] ||= {}
                    matches[var.name][var.unencode(vals.first)] = var.unencode(vals.last)
                  end
                end
              else
                matches[var.name] = nil
              end
            elsif var.prefix
              scanned = scanner.scan(/((?:#{UNRESERVED_SET}|,){0,#{var.prefix}})/)
              if scanned
                if scanner[1] =~ /,/
                  matches[var.name] = var.unencode(scanner[1].split(','))
                else
                  matches[var.name] = var.unencode(scanner[1])
                end
              else
                matches[var.name] = nil
              end
            else
              scanned = scanner.scan(/#{UNRESERVED_SCAN}/)
              if scanned
                if scanner[1] =~ /,/
                  matches[var.name] = var.unencode(scanner[1].split(','))
                else
                  matches[var.name] = var.unencode(scanner[1])
                end
              else
                matches[var.name] = nil
              end
            end
          end
          matches
        else
          # If leader was not found, 
          variables.each do |var|
            matches[var.name] = nil
          end
          matches
        end
      end
    end

    class OpPlain < Expression
      def self.leader; ""; end
      def self.joiner; ","; end
    end

    class OpReserved < Expression
      def self.allows_reserved?; true; end
    end
    class OpFragment < Expression
      def self.allows_reserved?; true; end
      def self.leader; "#"; end
      def self.joiner; ","; end
    end

    class OpPath < Expression
      def self.leader; "/"; end
      def self.joiner; "/"; end
    end

    class OpLabel < Expression
      def self.leader; "."; end
      def self.joiner; "."; end
    end

    class OpPathParams < Expression
      def self.leader; ";"; end
      def self.joiner; ";"; end
      def self.tagged_value; PathParamTaggedValue; end
    end

    class OpFormContinuation < Expression
      def self.leader; "&"; end
      def self.joiner; "&"; end
      def self.tagged_value; NamedTaggedValue; end
    end

    class OpForm < Expression
      def self.leader; "?"; end
      def self.joiner; "&"; end
      def self.tagged_value; NamedTaggedValue; end
      # def self.extract_values(scanner, matches, variables)
      #   scan_state = :start
      #   variables.each do |var|
      #     scanned = scanner.getch
      #     if scan_state == :start
      #       return unless scanned == "?"
      #       scanned = scanner.scan(/(#{var.name})=#{UNRESERVED_SCAN}/)
      #       if scanned
      #         matches[var.name] = scanner[2]
      #       end
      #       scan_state = :next
      #     else
      #       return unless scanned == "&"
      #       scanned = scanner.scan(/(#{var.name})=#{UNRESERVED_SCAN}/)
      #       if scanned
      #         matches[var.name] = scanner[2]
      #       end
      #     end
      #   end
      #   matches
      # end
    end
  end
end
