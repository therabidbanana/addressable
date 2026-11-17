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

    # Literal text between expressions, as the pattern writes it.
    class Literal
      attr_reader :text

      def initialize(text)
        @text = text
        # Expansion pct-encodes non-ASCII literals (RFC 6570 section 3.1),
        # and they don't change between calls, so they're encoded once.
        @expansion =
          if text.ascii_only?
            text
          else
            Addressable::URI.encode_component(text, LITERAL_ENCODE)
          end
      end

      # The text in an expanded URI, with non-ASCII characters pct-encoded.
      # A pattern that isn't UTF-8 has its bytes encoded as they are.
      def expand(_values)
        @expansion
      end

      # The text in a partially expanded pattern: as written, since expand
      # encodes it later.
      def partial_expand(_values)
        @text
      end

      def variables
        []
      end
    end
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


      # The varspec as the pattern wrote it. VARSPEC allows no leading zero
      # in a prefix, so the number reads back the same.
      def varspec
        if @prefix
          "#{name}:#{@prefix}"
        elsif @explode
          "#{name}*"
        else
          name
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

      ##
      # The expression's expansion: its defined variables' values, joined
      # with its leader and separator.
      #
      # @param [Values] values The expansion's values.
      #
      # @return [String] The expansion, or "" if no variable is defined.
      def expand(values)
        list = variables.map do |variable|
          values.expand(variable)
        end
        list.compact!
        list.empty? ? "" : joined_values(list)
      end

      def self.operator; ""; end
      def self.leader; ""; end
      def self.joiner; ","; end

      ##
      # The expression's text in a partially expanded pattern, as
      # Template#partial_expand writes it. An expression whose variables are
      # all given is expanded, and one with none given is kept. Otherwise
      # its given variables are expanded and its missing ones kept, in runs,
      # and a given variable that's undefined is dropped, so that it doesn't
      # split the missing variables around it.
      #
      # @param [Values] values The expansion's values.
      #
      # @return [String] The expression's new text.
      def partial_expand(values)
        given = lambda { |variable| values.key?(variable.name) }
        defined = lambda { |variable| values.defined_value?(variable.name) }
        operator = self.class.operator
        return expand(values) if variables.all?(&given)
        return source(operator, variables) if variables.none?(&given)

        vars = variables
        if operator == "?"
          # The first defined variable starts the query, so it goes first.
          first = vars.find(&defined)
          if first
            vars = [first] +
              vars.reject { |variable| variable.varspec == first.varspec }
          end
        end
        vars = vars.select do |variable|
          !given.call(variable) || defined.call(variable)
        end
        # Consecutive variables that are all given, or all missing, stay in
        # one expression, so that their separator is kept.
        runs = vars.chunk(&given).to_a
        if operator == "" || operator == "+" || operator == "#"
          return partial_comma_runs(values, runs, defined)
        end
        runs.inject(String.new) do |acc, (is_given, run)|
          if is_given
            value = run_expansion(operator, run, values)
            # After a value, the rest of a query continues with "&".
            operator = "&" if operator == "?" && !value.empty?
            acc << value
          else
            acc << source(operator, run)
          end
        end
      end

      def joined_values(list)
        self.class.leader + list.flat_map{|val|
          val.to_str
        }.join(self.class.joiner)
      end

      private

      # Partially expands the runs of a simple, reserved or fragment
      # expression, whose values are separated by commas, as Template's
      # transform_partial_comma_runs does. A missing variable keeps its
      # separator only if it ends up undefined. After the first value, a
      # fragment expression's runs use reserved expansion, which adds no
      # second "#".
      def partial_comma_runs(values, runs, defined)
        operator = self.class.operator
        started = false
        # Once a given variable is defined, a fragment expression's "#" is
        # certain, so it comes first, and every run uses reserved expansion.
        fragment = operator == "#" &&
          runs.any? { |is_given, run| is_given && run.any?(&defined) }
        result = fragment ? String.new("#") : String.new
        runs.inject(result) do |acc, (is_given, run)|
          run_operator =
            (started || fragment) && operator == "#" ? "+" : operator
          if is_given
            # An empty string is defined, so it still takes a separator.
            if run.any?(&defined)
              acc << "," if started
              started = true
            end
            acc << run_expansion(run_operator, run, values)
          else
            acc << source(run_operator, run)
          end
        end
      end

      # Expands a run of variables with an operator: this expression's, or
      # the "&" that continues a query, or the "+" that continues a
      # fragment. Those allow the same characters and join named values
      # the same way as "?" and "#", so the variables don't change.
      def run_expansion(operator, run, values)
        expression_class =
          case operator
          when "&" then OpFormContinuation
          when "+" then OpReserved
          else self.class
          end
        expression_class.new(run).expand(values)
      end

      # An expression's text for a run of variables.
      def source(operator, run)
        "{#{operator}#{run.map(&:varspec).join(',')}}"
      end

      public

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
      def self.operator; "+"; end
      def self.allows_reserved?; true; end
    end
    class OpFragment < Expression
      def self.operator; "#"; end
      def self.allows_reserved?; true; end
      def self.leader; "#"; end
      def self.joiner; ","; end
    end

    class OpPath < Expression
      def self.operator; "/"; end
      def self.leader; "/"; end
      def self.joiner; "/"; end
    end

    class OpLabel < Expression
      def self.operator; "."; end
      def self.leader; "."; end
      def self.joiner; "."; end
    end

    class OpPathParams < Expression
      def self.operator; ";"; end
      def self.leader; ";"; end
      def self.joiner; ";"; end
      def self.tagged_value; PathParamTaggedValue; end
    end

    class OpFormContinuation < Expression
      def self.operator; "&"; end
      def self.leader; "&"; end
      def self.joiner; "&"; end
      def self.tagged_value; NamedTaggedValue; end
    end

    class OpForm < Expression
      def self.operator; "?"; end
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
