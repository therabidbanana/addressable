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
require "addressable/template/lexer"
require "strscan"

module Addressable
  class Template
    # The :machine engine. A Template whose engine is :machine hands its
    # operations to its own ParsedTemplate, which parses the pattern once
    # into literal strings and expression nodes (see Lexer and Machine), then
    # expands and matches by walking those nodes instead of building a
    # regular expression.
    #
    # It isn't finished. An operation or argument it doesn't support yet
    # raises NotImplementedError rather than falling back to Template's
    # regexp code, so the specs run with TEMPLATE_MODE=machine list exactly
    # what's left to build.
    #
    # @api private
    class ParsedTemplate
      # Raised inside #match when the URI stops fitting the nodes; #match
      # rescues it and returns nil.
      class NoMatch < StandardError
      end

      # Parses the template's pattern. Like Template.new, this never raises
      # for a pattern that isn't valid: the first invalid token's error is
      # raised by the first operation that needs a valid pattern.
      def initialize(template)
        @template = template
        @nodes = Lexer.new.parse_nodes(template.pattern)
        @invalid = @nodes.find { |node| node.is_a?(Machine::Invalid) }
      end

      def expand(mapping, processor, normalize_values, &block)
        result = String.new
        values = Values.new(Values.mapping_or_block(mapping, block),
          normalize_values, processor)
        nodes.each do |node|
          if node.is_a?(String)
            result << node
          else
            expand_varspec(values, node) do |expansion|
              result << expansion
            end
          end
        end
        return Addressable::URI.parse(result)
      end

      def partial_expand(_mapping, _processor, _normalize_values)
        unsupported("partial_expand")
      end

      def match(uri_or_string, processor)
        unsupported("match with a processor") unless processor.nil?
        scanner = StringScanner.new(uri_or_string.to_s)
        mapping = {}
        nodes.each do |node|
          extracted = nil
          if node.is_a?(String)
            extracted = scanner.scan(node)
            raise NoMatch unless extracted
          else
            extracted = node.extract_values(scanner, mapping)
            raise NoMatch unless extracted
          end
        end
        MatchData.new(uri_or_string, @template, mapping)
      rescue NoMatch
      end

      # Like Template#variables, this doesn't raise for a pattern that isn't
      # valid: it lists the names of the expressions Template's scan finds,
      # in order, once each.
      def variables
        @nodes.flat_map do |node|
          if node.is_a?(String)
            []
          elsif node.is_a?(Machine::Invalid)
            node.names
          else
            node.variables.map(&:name)
          end
        end.uniq
      end

      # Template has no syntax for default values, so it always returns {}.
      def variable_defaults
        {}
      end

      def named_captures
        unsupported("named_captures")
      end

      private

      # The pattern's literals and expressions, or Template's error for its
      # first invalid token.
      def nodes
        raise @invalid.error_class, @invalid.message if @invalid
        @nodes
      end

      def expand_varspec(values, varspec)
        val = varspec.join_expansions(values)
        yield val if val
      end

      def unsupported(operation)
        raise NotImplementedError,
          "the :machine template engine doesn't support #{operation} yet"
      end
    end
  end
end
