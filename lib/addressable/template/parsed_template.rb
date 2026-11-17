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

      # Expands the template into a URI. Literals are pct-encoded, and every
      # "#" after the first is encoded. The text is UTF-8, as Template's is,
      # whatever the pattern's encoding: values are UTF-8 (RFC 6570 section
      # 3.2.1), and literals are pct-encoded ASCII.
      def expand(mapping, processor, normalize_values, &block)
        values = values_for(mapping, processor, normalize_values, block)
        result = render(Encoding::UTF_8) { |node| node.expand(values) }
        Addressable::URI.parse(Values.encode_later_number_signs(result))
      end

      # Expands the expressions whose variables the mapping gives, and keeps
      # the rest, into a new template with the same engine. Literals are
      # kept as the pattern writes them; expand encodes them later.
      # Template#partial_expand edits a copy of the pattern, so the new one
      # keeps the pattern's encoding.
      def partial_expand(mapping, processor, normalize_values, &block)
        values = values_for(mapping, processor, normalize_values, block)
        result = render(@template.pattern.encoding) do |node|
          node.partial_expand(values)
        end
        Addressable::Template.new(result, engine: @template.engine)
      end

      def match(uri_or_string, processor)
        unsupported("match with a processor") unless processor.nil?
        scanner = StringScanner.new(uri_or_string.to_s)
        mapping = {}
        nodes.each do |node|
          extracted = nil
          if node.is_a?(Machine::Literal)
            extracted = scanner.scan(node.text)
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
          if node.is_a?(Machine::Invalid)
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

      # Raises the error for a pattern that isn't valid, then the values for
      # one expansion, from the mapping or the block.
      def values_for(mapping, processor, normalize_values, block)
        nodes
        Values.new(Values.mapping_or_block(mapping, block), normalize_values,
          processor)
      end

      # Joins each node as the block writes it, into a string in the given
      # encoding.
      def render(encoding)
        result = String.new.force_encoding(encoding)
        @nodes.each { |node| result << yield(node) }
        result
      end

      def unsupported(operation)
        raise NotImplementedError,
          "the :machine template engine doesn't support #{operation} yet"
      end
    end
  end
end
