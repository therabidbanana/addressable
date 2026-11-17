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
    variable_char_class =
      Addressable::URI::CharacterClasses::ALPHA +
      Addressable::URI::CharacterClasses::DIGIT + '_'

    # Atomic, as in Template, so a long name can't backtrack.
    var_char =
      "(?>(?:[#{variable_char_class}]|%[a-fA-F0-9][a-fA-F0-9])+)"

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

      ##
      # Adds the steps that match the literal to the matcher (see
      # Matching.literal_units).
      #
      # @param [Matcher] matcher The matcher.
      # @param [TrueClass, FalseClass] fragment
      #   Whether a fragment may have started before the literal.
      def match_steps(matcher, fragment)
        matcher.literal(Matching.literal_units(@text, fragment))
      end

      # The literal's part of Template#to_regexp, matching it as
      # match_steps does.
      #
      # @param [TrueClass, FalseClass] fragment
      #   Whether a fragment may have started before the literal.
      def regexp_source(fragment, _label_dots)
        Matching.literal_source(Matching.literal_units(@text, fragment))
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

      # The expression as the pattern writes it.
      def text
        source(self.class.operator, variables)
      end

      ##
      # Adds the steps that match the expression to the matcher, in the
      # order of Template's reference regexp (template_match_spec.rb):
      # nothing first, then the leader and each variable's value, which may
      # be left out, with an optional joiner between them. Each value is
      # captured, for Matching.match_data.
      #
      # @param [Matcher] matcher The matcher.
      # @param [TrueClass, FalseClass] fragment
      #   Whether a fragment may have started before the expression, so
      #   that expansion encoded its "#" leader as "%23".
      # @param [TrueClass, FalseClass] label_dots
      #   Whether a label's value can contain "."
      #   (Matching.label_takes_dots?).
      # @param [#match, nil] processor
      #   A processor whose match method may give a variable's value a
      #   pattern of its own, which then has to match.
      def match_steps(matcher, fragment, label_dots, processor = nil)
        # Asked for every variable before any steps, as Template asks.
        patterns = variables.map do |variable|
          processor && processor.match(variable.name)
        end
        leader = self.class.leader
        matcher.nothing_or do
          if leader == "#" && fragment
            matcher.literal([["#", "%23"]])
          elsif !leader.empty?
            matcher.exact(leader)
          end
          variables.each_with_index do |variable, position|
            if position > 0
              matcher.optional { matcher.exact(self.class.joiner) }
            end
            if patterns[position]
              matcher.capture do
                matcher.processor_pattern(patterns[position].to_s)
              end
            else
              matcher.optional do
                matcher.capture do
                  variable_steps(matcher, variable, label_dots)
                end
              end
            end
          end
        end
      end

      private

      # A variable's value: exploded, up to the next comma, or as its
      # operator takes a value.
      def variable_steps(matcher, variable, label_dots)
        if variable.explode
          matcher.repeat(self.class.joiner, self.class.joiner_required?) do
            self.class.member_steps(matcher)
          end
        elsif variables.size > 1 && self.class.allows_reserved? &&
            variable.varspec != variables.last.varspec
          # A + or # variable before the last takes its value up to the
          # next comma. As in Template, a variable is the last one if its
          # varspec is the same as the last varspec.
          matcher.possessive_run(:reserved_no_comma)
        else
          self.class.value_steps(matcher, label_dots)
        end
      end

      public

      ##
      # The expression's part of Template#to_regexp, as Template's builder
      # writes it: nothing, or the leader and each variable's value, which
      # may be left out, with an optional joiner between them. Each value is
      # a group named after its variable (Matching.capture_name).
      #
      # @param [TrueClass, FalseClass] fragment
      #   Whether a fragment may have started before the expression, so
      #   that expansion encoded its "#" leader as "%23".
      # @param [TrueClass, FalseClass] label_dots
      #   Whether a label's value can contain "."
      #   (Matching.label_takes_dots?).
      #
      # @return [String] The regular expression source.
      def regexp_source(fragment, label_dots)
        leader = self.class.leader
        leader =
          if leader == "#" && fragment
            NUMBER_SIGN_EITHER_FORM
          else
            Regexp.escape(leader)
          end
        values = variables.map do |variable|
          name = Matching.capture_name(variable.name)
          "(?<#{name}>#{variable_source(variable, label_dots)})?"
        end
        "(?:|#{leader}#{values.join("#{joiner_source}?")})"
      end

      private

      # The joiner, escaped for a regular expression.
      def joiner_source
        Regexp.escape(self.class.joiner)
      end

      # A variable's value, as variable_steps matches it.
      def variable_source(variable, label_dots)
        if variable.explode
          member = self.class.member_source
          "#{member}(?:#{joiner_source}#{member})*"
        elsif variables.size > 1 && self.class.allows_reserved? &&
            variable.varspec != variables.last.varspec
          "#{RESERVED_NO_COMMA}*+"
        else
          self.class.value_source(label_dots)
        end
      end

      # A value: unreserved characters, as few as can be first.
      def self.value_steps(matcher, _label_dots)
        matcher.lazy_run(:unreserved)
      end

      def self.value_source(_label_dots)
        "#{UNRESERVED}*?"
      end

      # An exploded value's member.
      def self.member_steps(matcher)
        value_steps(matcher, false)
      end

      def self.member_source
        value_source(false)
      end

      # Whether an exploded value's members need the joiner between them.
      def self.joiner_required?
        false
      end
    end

    class OpPlain < Expression
      def self.leader; ""; end
      def self.joiner; ","; end
      def self.joiner_required?; true; end
    end

    class OpReserved < Expression
      def self.operator; "+"; end
      def self.allows_reserved?; true; end

      def self.value_steps(matcher, _label_dots)
        matcher.lazy_run(:reserved)
      end

      def self.value_source(_label_dots)
        "#{RESERVED}*?"
      end

      # A member takes everything up to the next comma.
      def self.member_steps(matcher)
        matcher.possessive_run(:reserved_no_comma)
      end

      def self.member_source
        "#{RESERVED_NO_COMMA}*+"
      end
    end
    class OpFragment < Expression
      def self.operator; "#"; end
      def self.allows_reserved?; true; end
      def self.leader; "#"; end
      def self.joiner; ","; end

      def self.value_steps(matcher, label_dots)
        OpReserved.value_steps(matcher, label_dots)
      end

      def self.member_steps(matcher)
        OpReserved.member_steps(matcher)
      end

      def self.value_source(label_dots)
        OpReserved.value_source(label_dots)
      end

      def self.member_source
        OpReserved.member_source
      end
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

      # A label's value can't contain a ".", unless nothing after it could
      # continue it, when it takes every character up to the delimiter.
      def self.value_steps(matcher, label_dots)
        if label_dots
          matcher.possessive_run(:unreserved)
        else
          matcher.lazy_run(:unreserved_no_dot)
        end
      end

      def self.value_source(label_dots)
        if label_dots
          "#{UNRESERVED}*+"
        else
          "#{UNRESERVED.gsub('\.', '')}*?"
        end
      end
    end

    class OpPathParams < Expression
      def self.operator; ";"; end
      def self.leader; ";"; end
      def self.joiner; ";"; end
      def self.tagged_value; PathParamTaggedValue; end

      # A name, then an optional "=" and a value.
      def self.value_steps(matcher, _label_dots)
        matcher.greedy_run(:unreserved)
        matcher.optional { matcher.exact("=") }
        matcher.lazy_run(:unreserved)
      end

      # Template's regexp writes the name with "=" and the name alone as
      # two choices, which match the same strings in the same order.
      def self.value_source(_label_dots)
        "(?:#{UNRESERVED}*=#{UNRESERVED}*?|#{UNRESERVED}*)"
      end

      # Name and value characters and "=", in any order.
      def self.member_source
        "(?:#{UNRESERVED}|=)*"
      end
    end

    class OpFormContinuation < Expression
      def self.operator; "&"; end
      def self.leader; "&"; end
      def self.joiner; "&"; end
      def self.tagged_value; NamedTaggedValue; end

      # A name, "=", and a value.
      def self.value_steps(matcher, _label_dots)
        matcher.greedy_run(:unreserved)
        matcher.exact("=")
        matcher.lazy_run(:unreserved)
      end

      def self.value_source(_label_dots)
        "#{UNRESERVED}*=#{UNRESERVED}*?"
      end

      # A name, then the value, with as many "=" as it has.
      def self.member_source
        "#{UNRESERVED}*=(?:#{UNRESERVED}*=)*#{UNRESERVED}*?"
      end
    end

    class OpForm < Expression
      def self.operator; "?"; end
      def self.leader; "?"; end
      def self.joiner; "&"; end
      def self.tagged_value; NamedTaggedValue; end

      def self.value_steps(matcher, label_dots)
        OpFormContinuation.value_steps(matcher, label_dots)
      end

      def self.value_source(label_dots)
        OpFormContinuation.value_source(label_dots)
      end

      def self.member_source
        OpFormContinuation.member_source
      end
    end
  end
end
