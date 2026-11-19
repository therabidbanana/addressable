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

module Addressable
  class Template
    module Machine
      # A variable's expanded value, for its expression to join. keypairs
      # says an array holds key=value pairs; composite says the value was a
      # list or associative array before it was expanded, so it isn't empty
      # even when its members join to an empty string (RFC 6570 section
      # 3.2.7).
      class TaggedValue < Struct.new(:name, :value, :keypairs, :composite)
        # The value, or its members, for Expression#joined_values to join.
        # A processor's transform result can hold anything, so members are
        # left for Array#join to flatten and convert.
        def parts
          if value.is_a?(Array)
            value
          else
            value.to_s
          end
        end
      end

      # Path-style parameters (;). An empty member or pair value gets no
      # "=" (RFC 6570 appendix A), but a list or associative array whose
      # members join to an empty string does.
      class PathParamTaggedValue < TaggedValue
        def parts
          if keypairs
            # Values are pct-encoded, so a pair that ends in "=" is empty.
            value.map { |pair| pair.end_with?("=") ? pair[0...-1] : pair }
          elsif value.is_a?(Array)
            value.map { |inner| inner == "" ? name : "#{name}=#{inner}" }
          elsif (value && value != "") || composite
            "#{name}=#{value}"
          else
            name
          end
        end
      end

      # Form-style query (? and &). Each value or member gets its name and
      # "=", even when it's empty; key=value pairs already have their keys.
      class NamedTaggedValue < TaggedValue
        def parts
          return super if keypairs
          if value.is_a?(Array)
            value.map { |inner| "#{name}=#{inner}" }
          else
            "#{name}=#{value}"
          end
        end
      end
    end
  end
end
