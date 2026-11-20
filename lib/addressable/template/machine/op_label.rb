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

        private

        # --- Matching ---

        # A label's value can't contain a ".", unless nothing after it
        # could continue it, when it takes every character up to the
        # delimiter. label_dots is only true for a lone, unexploded
        # variable, so a member, which uses this too, never takes dots.
        def value_steps(matcher, _variable = nil)
          if label_dots
            matcher.possessive_run(:unreserved)
          else
            matcher.greedy_run(:unreserved_no_dot)
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
