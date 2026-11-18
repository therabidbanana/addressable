require "addressable/template/machine/expression"

module Addressable
  class Template
    module Machine
      # Label expansion with a dot prefix ({.var}).
      class OpLabel < Expression
        def self.operator; "."; end
        def self.leader; "."; end
        def self.joiner; "."; end

        private

        # --- Matching ---

        # A label's value can't contain a ".", unless nothing after it
        # could continue it, when it takes every character up to the
        # delimiter. label_dots is only true for a lone, unexploded
        # variable, so a member, which uses this too, never takes dots.
        def value_steps(matcher)
          if label_dots
            matcher.possessive_run(:unreserved)
          else
            matcher.lazy_run(:unreserved_no_dot)
          end
        end

        # --- Regexp ---

        def value_source
          if label_dots
            "#{UNRESERVED}*+"
          else
            "#{UNRESERVED.gsub('\.', '')}*?"
          end
        end
      end
    end
  end
end
