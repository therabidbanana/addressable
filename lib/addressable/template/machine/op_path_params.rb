require "addressable/template/machine/expression"

module Addressable
  class Template
    module Machine
      # Path-style parameter expansion ({;var}).
      class OpPathParams < Expression
        def self.operator; ";"; end
        def self.leader; ";"; end
        def self.joiner; ";"; end
        def self.tagged_value; PathParamTaggedValue; end

        private

        # --- Matching ---

        # A name, then an optional "=" and a value.
        def value_steps(matcher)
          matcher.greedy_run(:unreserved)
          matcher.optional { matcher.exact("=") }
          matcher.lazy_run(:unreserved)
        end

        # --- Regexp ---

        # 2.10.0's regexp writes the name with "=" and the name alone as
        # two choices, which match the same strings in the same order.
        def value_regexp_source
          "(?:#{UNRESERVED}*=#{UNRESERVED}*?|#{UNRESERVED}*)"
        end

        # Name and value characters and "=", in any order.
        def member_regexp_source
          "(?:#{UNRESERVED}|=)*"
        end

        def group_regexp_source(variable, position)
          if exploded_before?(position)
            # Exploded values were tried longest first, so whatever this
            # variable could match after an exploded one, that one already
            # tried matching itself, and it's always empty.
            group(variable, "")
          elsif position > 0
            # Values were tried longest first, and splitting an earlier
            # variable's run of characters with this one never gave a
            # different result, so this one may only start after that run.
            value = variable_regexp_source(variable)
            group(variable, "(?:#{NOT_AFTER_VALUE}#{value})?")
          else
            optional_group(variable)
          end
        end
      end
    end
  end
end
