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

        # :regexp's regexp writes the name with "=" and the name alone as
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
            named_group_regexp_source(variable, "")
          elsif position > 0
            # Values were tried longest first, and splitting an earlier
            # variable's run of characters with this one never gave a
            # different result, so this one may only start after that run.
            value = variable_regexp_source(variable)
            named_group_regexp_source(
              variable, "(?:#{NOT_AFTER_VALUE}#{value})?"
            )
          else
            optional_group_regexp_source(variable)
          end
        end
      end
    end
  end
end
