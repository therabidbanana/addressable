# frozen_string_literal: true

# encoding:utf-8
#--
# Copyright (C) Bob Aman, David Haslem
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

require "addressable/uri"
require "addressable/template_lexer"
require "strscan"

module Addressable
  class UriTemplate
    class NoMatch < StandardError
    end

    def initialize(uri_template)
      @nodes = Addressable::TemplateLexer.new.parse_nodes(uri_template)
    end

    # Generates a hash with string keys
    #
    # @param [Hash] mapping A mapping hash to normalize
    #
    # @return [Hash]
    #   A hash with stringified keys
    def normalize_keys(mapping)
      return mapping.inject({}) do |accu, pair|
        name, value = pair
        if Symbol === name
          name = name.to_s
        elsif name.respond_to?(:to_str)
          name = name.to_str
        else
          raise TypeError,
                "Can't convert #{name.class} into String."
        end
        accu[name] = value
        accu
      end
    end

    def expand(mapping)
      result = String.new
      mapping = normalize_keys(mapping)
      @nodes.each do |node|
        if node.is_a?(String)
          result << node
        else
          expand_varspec(mapping, *node) do |expansion|
            result << expansion
          end
        end
      end
      result
    end

    def expand_varspec(mapping, op, vars)
      val = op.concat(mapping, vars)
      yield val if val
    end

    class MatchData
      ##
      # Creates a new MatchData object.
      # MatchData objects should never be instantiated directly.
      #
      # @param [Addressable::URI] uri
      #   The URI that the template was matched against.
      def initialize(uri, template, mapping)
        @uri = uri.dup.freeze
        @template = template
        @mapping = mapping.dup.freeze
      end

      ##
      # @return [Addressable::URI]
      #   The URI that the Template was matched against.
      attr_reader :uri

      ##
      # @return [Addressable::Template]
      #   The Template used for the match.
      attr_reader :template

      ##
      # @return [Hash]
      #   The mapping that resulted from the match.
      #   Note that this mapping does not include keys or values for
      #   variables that appear in the Template, but are not present
      #   in the URI.
      attr_reader :mapping

      ##
      # @return [Array]
      #   The list of variables that were present in the Template.
      #   Note that this list will include variables which do not appear
      #   in the mapping because they were not present in URI.
      def variables
        self.template.variables
      end
      alias_method :keys, :variables
      alias_method :names, :variables
    end
    def match(uri_or_string)
      scanner = StringScanner.new(uri_or_string.to_s)
      mapping = {}
      @nodes.each do |node|
        extracted = nil
        if node.is_a?(String)
          extracted = scanner.scan(node)
          raise NoMatch unless extracted
        else
          extracted = node[0].extract_values(scanner, node[1])
          raise NoMatch unless extracted
          mapping.merge!(extracted)
        end
      end
      MatchData.new(uri_or_string, self, mapping)
    rescue NoMatch
    end
  end
end
