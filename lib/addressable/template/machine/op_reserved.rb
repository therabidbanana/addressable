require "addressable/template/machine/expression"

# Written as Addressable::Template, not nested, as in machine.rb.
class Addressable::Template
  module Machine
    # Reserved expansion ({+var}).
    class OpReserved < Expression
      def self.operator; "+"; end
      def self.allows_reserved?; true; end

      # --- Regexp ---

      # An unexploded last variable matches any characters that an
      # expression can, and can end anywhere.
      def absorbs?(_previous)
        !variables.last.explode
      end

      def may_start_with_comma?
        true
      end

      private

      # --- Expansion ---

      def partial_runs(values, runs)
        partial_comma_runs(values, runs)
      end

      # --- Matching ---

      def value_steps(matcher)
        matcher.lazy_run(:reserved)
      end

      # A member takes everything up to the next comma.
      def member_steps(matcher)
        matcher.possessive_run(:reserved_no_comma)
      end

      # --- Regexp ---

      def value_source
        "#{RESERVED}*?"
      end

      # A member takes everything up to the next comma.
      def member_source
        "#{RESERVED_NO_COMMA}*+"
      end

      def values_source
        if single_value? && following.is_a?(OpPlain) &&
            following.single_value?
          # Values were tried shortest first, and the next expression can
          # match any unreserved characters, so the value only needs to
          # end after a character that the next expression couldn't
          # match.
          group(variables.first, "#{RESERVED}*?#{NOT_AFTER_VALUE}") + "?"
        elsif variables.size > 1 && !comma_follows? &&
            variables.none?(&:explode) &&
            variables[0...-1].none? { |variable| last?(variable) }
          nested_values_source
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
      def nested_values_source
        last = variables.size - 1
        nested = variables[0...last].reverse.inject("") do |inner, variable|
          "(?:#{group(variable, "#{RESERVED_NO_COMMA}*+")}" \
            "#{joiner_source}?+#{inner}|(?=#{RESERVED_NO_COMMA}))"
        end
        nested + group_source(variables.last, last)
      end

      def group_source(variable, position)
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
          optional_group(variable)
        end
      end
    end

    # Fragment expansion ({#var}): reserved expansion after a "#" leader.
    class OpFragment < OpReserved
      def self.operator; "#"; end
      def self.leader; "#"; end
      def self.continuation; OpReserved; end

      # --- Regexp ---

      # Its "#" leader has to come first.
      def absorbs?(_previous)
        false
      end

      def may_start_with_comma?
        false
      end
    end
  end
end
