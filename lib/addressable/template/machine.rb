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

    # In Template's regexp: a position that isn't right after a character a
    # value can hold, so a value starting there can't be split from one
    # that ended just before.
    NOT_AFTER_VALUE =
      "(?<![#{Addressable::URI::CharacterClasses::UNRESERVED}])" \
      "(?<![^\\x00-\\x7F])"

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
      def regexp_source(fragment, _label_dots, _following, _comma_follows)
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
        elsif self.class.allows_reserved? && !last?(variable)
          # A + or # variable before the last takes its value up to the
          # next comma.
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
      # @param [Expression, nil] following
      #   The expression right after this one, if no literal text comes
      #   between them.
      # @param [TrueClass, FalseClass] comma_follows
      #   Whether the text after this expression could start with a comma.
      #
      # @return [String] The regular expression source.
      def regexp_source(fragment, label_dots, following, comma_follows)
        leader = self.class.leader
        leader =
          if leader == "#" && fragment
            NUMBER_SIGN_EITHER_FORM
          else
            Regexp.escape(leader)
          end
        if following && following.absorbs?(self)
          # Each expression tried its empty alternative first. When the
          # next one can match anything this one could, followed by
          # anything it could match on its own, every other choice ends
          # where the empty one can also end, so the empty alternative
          # always gave the first match.
          "(?:|(?!)#{leader}#{joined_groups(label_dots)})"
        else
          "(?:|#{leader}#{values_source(label_dots, following, comma_follows)})"
        end
      end

      # Whether this expression, right after the other one, can match
      # anything the other could, followed by anything it could match on
      # its own. Only a default or + expression can.
      def absorbs?(_previous)
        false
      end

      # Whether this expression could match a string that starts with a
      # comma. Only a default or + expression, which has no leader, can.
      def may_start_with_comma?
        false
      end

      # Whether the expression is one variable that isn't exploded.
      def single_value?
        variables.size == 1 && !variables.first.explode
      end

      private

      # The variables' groups, as Template's builder writes them for what
      # follows the expression. A + or # expression writes them
      # differently before text that can't start with a comma.
      def values_source(label_dots, _following, _comma_follows)
        joined_groups(label_dots)
      end

      # Each variable's group, with an optional joiner between them.
      def joined_groups(label_dots)
        groups = variables.each_with_index.map do |variable, position|
          group_source(variable, position, label_dots)
        end
        groups.join("#{joiner_source}?")
      end

      ##
      # A variable's group in the regexp, as Template's builder writes it
      # for a default, / or . expression. The other operators override it.
      #
      # @param [Variable] variable The variable.
      # @param [Integer] position The variable's position in the expression.
      # @param [TrueClass, FalseClass] label_dots
      #   Whether a label's value can contain ".".
      #
      # @return [String] The regular expression source.
      def group_source(variable, position, label_dots)
        if variable.explode && exploded_after?(position)
          # Exploded values were tried shortest first, and a later exploded
          # variable can match whatever this one leaves, so once a split
          # fails, every split where this variable is longer fails too. Of
          # the values tried, only the leading joiners are shorter than
          # every value tried before them.
          group(variable, "(?:#{joiner_source})*")
        elsif !variable.explode && position < variables.size - 1
          # Values were tried shortest first, so a run of characters
          # without a joiner went to a later variable. The only other value
          # that could change the result is the whole run up to the next
          # joiner.
          value = self.class.value_source(label_dots)
          group(variable, "(?:#{value}(?=#{joiner_source}))??")
        else
          optional_group(variable, label_dots)
        end
      end

      # A group for the variable's value, left out when the value is.
      def optional_group(variable, label_dots)
        "#{group(variable, variable_source(variable, label_dots))}?"
      end

      # A group named after the variable (Matching.capture_name).
      def group(variable, source)
        "(?<#{Matching.capture_name(variable.name)}>#{source})"
      end

      # A variable's value: exploded, or as its operator takes a value.
      def variable_source(variable, label_dots)
        if variable.explode
          member = self.class.member_source
          "#{member}(?:#{joiner_source}#{member})*"
        else
          self.class.value_source(label_dots)
        end
      end

      # The joiner, escaped for a regular expression.
      def joiner_source
        Regexp.escape(self.class.joiner)
      end

      # Whether a variable before the position is exploded.
      def exploded_before?(position)
        variables.first(position).any?(&:explode)
      end

      # Whether a variable after the position is exploded.
      def exploded_after?(position)
        variables.drop(position + 1).any?(&:explode)
      end

      # As in Template, a variable is the last one if its varspec is the
      # same as the last varspec, so {+a,a} has no variable before the last.
      def last?(variable)
        variable.varspec == variables.last.varspec
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

      # An exploded last variable matches any unreserved characters and
      # commas, which is all a default or . expression matches, and a lone
      # variable matches any unreserved characters, which is all a . or a
      # lone default value matches.
      def absorbs?(previous)
        if variables.last.explode
          previous.is_a?(OpPlain) || previous.is_a?(OpLabel)
        elsif variables.size == 1
          previous.is_a?(OpLabel) ||
            (previous.is_a?(OpPlain) && previous.single_value?)
        else
          false
        end
      end

      # Every value but a lone unexploded one can hold a comma.
      def may_start_with_comma?
        !single_value?
      end
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

      # An unexploded last variable matches any characters that an
      # expression can, and can end anywhere.
      def absorbs?(_previous)
        !variables.last.explode
      end

      def may_start_with_comma?
        true
      end

      private

      def values_source(label_dots, following, comma_follows)
        if single_value? && following.is_a?(OpPlain) &&
            following.single_value?
          # Values were tried shortest first, and the next expression can
          # match any unreserved characters, so the value only needs to
          # end after a character that the next expression couldn't
          # match.
          group(variables.first, "#{RESERVED}*?#{NOT_AFTER_VALUE}") + "?"
        elsif variables.size > 1 && !comma_follows &&
            variables.none?(&:explode) &&
            variables[0...-1].none? { |variable| last?(variable) }
          nested_values_source(label_dots)
        else
          super
        end
      end

      # 2.9.0 tried each value with the joiner after it first, then the
      # value on its own, then skipping the variable, and every other
      # choice gave a value to a later variable that an earlier one had
      # already been tried with. A variable after a skipped one is skipped
      # too. Stopping before a joiner is left out, so this is only used
      # when no joiner can follow the expression.
      def nested_values_source(label_dots)
        last = variables.size - 1
        nested = variables[0...last].reverse.inject("") do |inner, variable|
          "(?:#{group(variable, "#{RESERVED_NO_COMMA}*+")}" \
            "#{joiner_source}?+#{inner}|(?=#{RESERVED_NO_COMMA}))"
        end
        nested + group_source(variables.last, last, label_dots)
      end

      def group_source(variable, position, label_dots)
        if exploded_before?(position)
          # Exploded values were tried longest first, so whatever this
          # variable could match after an exploded one, that one already
          # tried matching itself. Only the last unexploded variable can
          # stop inside a member, where an exploded variable can't.
          if !variable.explode && last?(variable)
            "#{group(variable, "#{RESERVED_NO_COMMA}*?")}?"
          else
            # 2.9.0 skipped the variable when it couldn't be empty.
            "(?:#{group(variable, '')}(?!#{RESERVED_NO_COMMA}))?"
          end
        elsif !variable.explode && !last?(variable)
          # A variable before the last takes its value up to the next
          # comma, as variable_steps matches it.
          "#{group(variable, "#{RESERVED_NO_COMMA}*+")}?"
        else
          optional_group(variable, label_dots)
        end
      end
    end
    # Reserved expansion after a "#" leader.
    class OpFragment < OpReserved
      def self.operator; "#"; end
      def self.leader; "#"; end

      # Its "#" leader has to come first.
      def absorbs?(_previous)
        false
      end

      def may_start_with_comma?
        false
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

      private

      def group_source(variable, position, label_dots)
        if exploded_before?(position)
          # Exploded values were tried longest first, so whatever this
          # variable could match after an exploded one, that one already
          # tried matching itself, and it's always empty.
          group(variable, "")
        elsif position > 0
          # Values were tried longest first, and splitting an earlier
          # variable's run of characters with this one never gave a
          # different result, so this one may only start after that run.
          value = variable_source(variable, label_dots)
          group(variable, "(?:#{NOT_AFTER_VALUE}#{value})?")
        else
          optional_group(variable, label_dots)
        end
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

      private

      def group_source(variable, position, label_dots)
        if position > 0 && variables[position - 1].explode
          # Whatever this variable could match after an exploded one, that
          # one already tried matching itself, unless it couldn't: an
          # exploded member can't be empty, so this variable may only start
          # right after an empty one.
          leader = Regexp.escape(self.class.leader)
          joiner = joiner_source
          after_empty = "(?<=#{leader}#{joiner}|#{joiner}#{joiner})"
          value = variable_source(variable, label_dots)
          "#{group(variable, after_empty + value)}?"
        else
          optional_group(variable, label_dots)
        end
      end
    end

    # A query's form continuation after a "?" leader.
    class OpForm < OpFormContinuation
      def self.operator; "?"; end
      def self.leader; "?"; end
    end
  end
end
