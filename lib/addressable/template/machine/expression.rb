require "addressable/template/machine/tagged_value"

# Written as Addressable::Template, not nested, as in machine.rb.
class Addressable::Template
  module Machine
    # An expression: its variables, and what every operator shares. It's
    # the base class of the operators, and is never built itself; its
    # defaults are simple expansion's, which OpPlain keeps. Each
    # operator's subclass declares its operator, leader and joiner with
    # class methods, and overrides the instance methods for the shapes of
    # its values. Its methods come in three parts: expansion, matching
    # (the steps it adds to a Matcher) and the regexp (its part of
    # Template#to_regexp, as Template's builder writes it).
    class Expression
      def self.operator; ""; end
      def self.leader; ""; end
      def self.joiner; ","; end

      def self.allows_reserved?
        false
      end

      def self.tagged_value
        TaggedValue
      end

      # Whether an exploded value's members need the joiner between them.
      def self.joiner_required?
        false
      end

      # In Template's regexp: a position that isn't right after a character
      # a value can hold, so a value starting there can't be split from one
      # that ended just before.
      NOT_AFTER_VALUE =
        "(?<![#{Addressable::URI::CharacterClasses::UNRESERVED}])" \
        "(?<![^\\x00-\\x7F])"

      attr_reader :variables

      # What matching the expression depends on around it, set by
      # ParsedTemplate#place_nodes.

      # Whether a fragment may have started before the expression, so that
      # expansion encoded its "#" leader as "%23".
      attr_accessor :fragment
      # Whether a label's value can contain "." (Matching.label_takes_dots?).
      attr_accessor :label_dots
      # The expression right after this one, if no literal text comes
      # between them.
      attr_accessor :following
      # Whether the text after the expression could start with a comma.
      attr_accessor :comma_follows

      def initialize(variables)
        @variables = variables
      end

      def tagged_value
        self.class.tagged_value
      end

      # The expression as the pattern writes it.
      def text
        source(self.class.operator, variables)
      end

      # --- Expansion ---

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
        self.class.leader + list.flat_map(&:parts).join(self.class.joiner)
      end

      # --- Matching ---

      ##
      # Adds the steps that match the expression to the matcher, in the
      # order of Template's reference regexp (template_match_spec.rb):
      # nothing first, then the leader and each variable's value, which may
      # be left out, with an optional joiner between them. Each value is
      # captured, for Matching.match_data.
      #
      # @param [Matcher] matcher The matcher.
      # @param [#match, nil] processor
      #   A processor whose match method may give a variable's value a
      #   pattern of its own, which then has to match.
      def match_steps(matcher, processor = nil)
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

      # --- Regexp ---

      ##
      # The expression's part of Template#to_regexp, as Template's builder
      # writes it: nothing, or the leader and each variable's value, which
      # may be left out, with an optional joiner between them. Each value is
      # a group named after its variable (Matching.capture_name).
      #
      # @return [String] The regular expression source.
      def regexp_source
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

      # As in Template, a variable is the last one if its varspec is the
      # same as the last varspec, so {+a,a} has no variable before the last.
      def last?(variable)
        variable.varspec == variables.last.varspec
      end

      # An expression's text for a run of variables.
      def source(operator, run)
        "{#{operator}#{run.map(&:varspec).join(',')}}"
      end

      # --- Expansion ---

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

      # --- Matching ---

      # A variable's value: exploded, up to the next comma, or as its
      # operator takes a value.
      def variable_steps(matcher, variable, label_dots)
        if variable.explode
          matcher.repeat(self.class.joiner, self.class.joiner_required?) do
            member_steps(matcher)
          end
        elsif self.class.allows_reserved? && !last?(variable)
          # A + or # variable before the last takes its value up to the
          # next comma.
          matcher.possessive_run(:reserved_no_comma)
        else
          value_steps(matcher, label_dots)
        end
      end

      # A value: unreserved characters, as few as can be first.
      def value_steps(matcher, _label_dots)
        matcher.lazy_run(:unreserved)
      end

      # An exploded value's member.
      def member_steps(matcher)
        value_steps(matcher, false)
      end

      # --- Regexp ---

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
          value = value_source(label_dots)
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
          member = member_source
          "#{member}(?:#{joiner_source}#{member})*"
        else
          value_source(label_dots)
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

      # A value: unreserved characters, as few as can be first.
      def value_source(_label_dots)
        "#{UNRESERVED}*?"
      end

      # An exploded value's member.
      def member_source
        value_source(false)
      end
    end
  end
end
