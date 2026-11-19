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
      # Simple string expansion ({var}).
      class OpPlain < Expression
        # --- Regexp ---

        # An exploded last variable matches any unreserved characters and
        # commas, which is all a default or . expression matches, and a
        # lone variable matches any unreserved characters, which is all a .
        # or a lone default value matches.
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

        private

        # --- Expansion ---

        def partial_runs(values, runs)
          partial_comma_runs(values, runs)
        end
      end
    end
  end
end
