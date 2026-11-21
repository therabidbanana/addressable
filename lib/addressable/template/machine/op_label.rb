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
      # Label expansion with a dot prefix ({.var}).
      class OpLabel < Expression
        def self.operator; "."; end
        def self.leader; "."; end
        def self.joiner; "."; end

        # A label's value holds "." only where label_dots allows it, and a
        # list's commas where it can be one (#holds_list?).
        def value_set(variable)
          if holds_list?(variable)
            label_dots ? :unreserved_or_comma : :unreserved_no_dot_or_comma
          else
            label_dots ? :unreserved : :unreserved_no_dot
          end
        end

        private

        # --- Matching ---

        # A label's value can't contain a ".", unless nothing after it
        # could continue it, when it takes every character up to the
        # delimiter. label_dots is only true for a lone, unexploded
        # variable, so a member, which uses this too, never takes dots.
        # With a prefix, the run up to the delimiter has to fit its
        # length: the delimiter can't follow anywhere sooner. Where the
        # delimiter is a comma, which a list's value holds too, the run
        # has to be able to give it back.
        def value_steps(matcher, variable = nil)
          set = value_set(variable)
          if label_dots && !(variable && variable.prefix) &&
              starts_outside?(following, Matcher::SETS.fetch(set))
            matcher.possessive_run(set)
          else
            value_run(matcher, variable, set)
          end
        end

        # --- Regexp ---

        def value_regexp_source
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
