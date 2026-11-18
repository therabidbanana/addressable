require "addressable/template/machine/expression"

module Addressable
  class Template
    module Machine
      # Form-style query continuation ({&var}).
      class OpFormContinuation < Expression
        def self.operator; "&"; end
        def self.leader; "&"; end
        def self.joiner; "&"; end
        def self.tagged_value; NamedTaggedValue; end

        private

        # --- Matching ---

        # A name, "=", and a value.
        def value_steps(matcher)
          matcher.greedy_run(:unreserved)
          matcher.exact("=")
          matcher.lazy_run(:unreserved)
        end

        # --- Regexp ---

        def value_source
          "#{UNRESERVED}*=#{UNRESERVED}*?"
        end

        # A name, then the value, with as many "=" as it has.
        def member_source
          "#{UNRESERVED}*=(?:#{UNRESERVED}*=)*#{UNRESERVED}*?"
        end

        def group_source(variable, position)
          if position > 0 && variables[position - 1].explode
            # Whatever this variable could match after an exploded one,
            # that one already tried matching itself, unless it couldn't: an
            # exploded member can't be empty, so this variable may only
            # start right after an empty one.
            leader = Regexp.escape(self.class.leader)
            joiner = joiner_source
            after_empty = "(?<=#{leader}#{joiner}|#{joiner}#{joiner})"
            value = variable_source(variable)
            "#{group(variable, after_empty + value)}?"
          else
            optional_group(variable)
          end
        end
      end

      # Form-style query ({?var}): a form continuation after a "?" leader.
      class OpForm < OpFormContinuation
        def self.operator; "?"; end
        def self.leader; "?"; end
        def self.continuation; OpFormContinuation; end

        private

        # --- Expansion ---

        # The query's "?" goes before its first defined value, so that
        # variable moves to the front. The rest keep their places, so the
        # final URI keeps the pattern's order wherever it can. As in
        # Template, it also takes the place of any other varspec written the
        # same way, so {?a,a} gives "?a=1" once.
        def partial_order(is_defined)
          first = variables.find(&is_defined)
          return variables unless first
          rest = variables.reject do |variable|
            variable.varspec == first.varspec
          end
          [first] + rest
        end
      end
    end
  end
end
