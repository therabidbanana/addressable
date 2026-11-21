# frozen_string_literal: true

#--
# Copyright (C) Bob Aman
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#++

require "addressable/template/machine/expression"

module Addressable
  class Template
    module Machine
      # Form-style query continuation ({&var}).
      class OpFormContinuation < Expression
        def self.operator; "&"; end
        def self.leader; "&"; end
        def self.joiner; "&"; end
        def self.names_values?; true; end
        def self.tagged_value; NamedTaggedValue; end

        private

        # --- Matching ---

        # The variable's name as written, "=", and a value.
        def value_steps(matcher, variable)
          matcher.exact("#{variable.name}=")
          value_run(matcher, variable, value_set(variable))
        end

        # A member: a name and "=", then the value. Expansion writes an "="
        # inside a value as "%3D", but a URI written some other way can
        # have one as it is (a token that ends "=="), so the value can
        # hold more runs that end in "=", as member_regexp_source allows:
        # as few as can be first, so that an "=" expansion wrote for what
        # follows isn't taken for the value's.
        def member_steps(matcher)
          matcher.greedy_run(:unreserved)
          matcher.exact("=")
          matcher.as_few_as_can_be do
            matcher.greedy_run(:unreserved)
            matcher.exact("=")
          end
          matcher.greedy_run(:unreserved)
        end

        # --- Regexp ---

        def value_regexp_source
          "#{UNRESERVED}*=#{UNRESERVED}*?"
        end

        # A name, then the value, with as many "=" as it has.
        def member_regexp_source
          "#{UNRESERVED}*=(?:#{UNRESERVED}*=)*#{UNRESERVED}*?"
        end

        def group_regexp_source(variable, position)
          if position > 0 && variables[position - 1].explode
            # Whatever this variable could match after an exploded one,
            # that one already tried matching itself, unless it couldn't: an
            # exploded member can't be empty, so this variable may only
            # start right after an empty one.
            leader = Regexp.escape(self.class.leader)
            joiner = joiner_regexp_source
            after_empty = "(?<=#{leader}#{joiner}|#{joiner}#{joiner})"
            value = variable_regexp_source(variable)
            "#{named_group_regexp_source(variable, after_empty + value)}?"
          else
            optional_group_regexp_source(variable)
          end
        end
      end

      # Form-style query ({?var}): a form continuation after a "?" leader.
      class OpForm < OpFormContinuation
        def self.operator; "?"; end
        def self.leader; "?"; end
        def self.partial_continuation; OpFormContinuation; end

        private

        # --- Expansion ---

        # The query's "?" goes before its first defined value, so that
        # variable moves to the front. The rest keep their places, so the
        # final URI keeps the pattern's order wherever it can. It also takes
        # the place of any other varspec written the same way, so {?a,a}
        # gives "?a=1" once.
        def partial_order(is_defined)
          first = variables.find(&is_defined)
          return variables unless first
          rest = variables.reject do |variable|
            variable.pattern_text == first.pattern_text
          end
          [first] + rest
        end
      end
    end
  end
end
