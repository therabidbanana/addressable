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
require "addressable/template/parser"
require "addressable/template/matcher"
require "addressable/template/matching"

module Addressable
  class Template
    # The :machine engine. A Template whose engine is :machine hands its
    # operations to its own ParsedTemplate, which holds the literal and
    # expression nodes that Parser parses the pattern into (see Machine).
    # It expands, matches and writes the regexp by walking those nodes.
    #
    # @api private
    class ParsedTemplate
      # Keeps the nodes Parser parses the pattern into. This never raises
      # for a pattern that isn't valid: the first invalid token's error is
      # raised by the first operation that needs a valid pattern.
      #
      # @param [String] pattern The template's pattern.
      def initialize(pattern)
        @pattern = pattern
        @nodes = Parser.new.parse_nodes(pattern)
        @invalid = @nodes.find { |node| node.is_a?(Machine::Invalid) }
        @matcher = nil
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
      # the rest, into a new template. Literals are kept as the pattern
      # writes them, and the new pattern keeps the pattern's encoding;
      # expand encodes literals later.
      def partial_expand(mapping, processor, normalize_values, &block)
        values = values_for(mapping, processor, normalize_values, block)
        result = render(@pattern.encoding) do |node|
          node.partial_expand(values)
        end
        Addressable::Template.new(result, engine: :machine)
      end

      # Matches the URI against the nodes' steps, which split it between
      # the varspecs, and Matching.match_data turns what each varspec
      # captured into the template's MatchData.
      #
      # @param [Addressable::Template] template The template, for its
      #   MatchData.
      # @param [Addressable::URI, #to_str] uri The URI.
      # @param [#match, #restore, nil] processor
      #   The processor, if any, with #match, #restore or both.
      def match(template, uri, processor)
        raise_if_invalid
        uri = Matching.parse_uri(uri)
        return nil if uri == false
        search = matcher_for(processor)
        # A nil URI raises NoMethodError here.
        captures = search.match(uri.to_str)
        return nil unless captures
        Matching.match_data(template, uri, search.expansions, captures,
          processor)
      end

      # Builds the matcher and the regexp, so a frozen template can still
      # give them. A pattern that isn't valid has neither, and freezing it
      # doesn't raise; every operation that would use them raises first.
      def freeze
        unless @invalid
          @matcher ||= build_matcher
          @regexp ||= build_regexp
        end
        super
      end

      # The variables' names, in the order the pattern first writes them,
      # once each. This doesn't raise for a pattern that isn't valid: an
      # invalid token gives the names Parser found in it.
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

      # Maps each variable name to the positions of its varspecs, counting
      # every varspec in the pattern from 1, as Template's regexp numbers its
      # groups: one per varspec, in order. Names are as the pattern writes
      # them, not Template's group names.
      def named_captures
        raise_if_invalid
        captures = {}
        position = 0
        @nodes.grep(Machine::Expression).each do |expression|
          expression.variables.each do |variable|
            position += 1
            (captures[variable.name] ||= []) << position
          end
        end
        captures
      end

      # The regexp Template's builder writes, from the nodes, built on first
      # use or by freeze.
      def to_regexp
        raise_if_invalid
        @regexp ||= build_regexp
      end

      private

      # Renders the nodes as the regexp's source. It starts as UTF-8, as
      # the builder's does, and takes the encoding of the pattern's
      # non-ASCII literals.
      def build_regexp
        result = render(Encoding::UTF_8, &:regexp_source)
        Regexp.new("\\A#{result}\\z")
      end

      # Raises Template's error for the pattern's first invalid token, if
      # it has one.
      def raise_if_invalid
        raise @invalid.error_class, @invalid.message if @invalid
      end

      # The matcher for a match with the processor. A processor's match
      # method can give a variable's value a pattern of its own, and is
      # asked on every call, so the matcher with its patterns is built for
      # the call. Otherwise the pattern's matcher is built on first use, or
      # by freeze, and kept.
      def matcher_for(processor)
        return build_matcher(processor) if processor.respond_to?(:match)
        @matcher ||= build_matcher
      end

      # Adds each node's steps to a new matcher, with the processor's
      # patterns, if any.
      def build_matcher(processor = nil)
        matcher = Matcher.new(expression_texts)
        @nodes.each { |node| node.match_steps(matcher, processor) }
        matcher.finish
      end

      # Each expression as the pattern writes it, in order.
      def expression_texts
        @nodes.grep(Machine::Expression).map(&:text)
      end

      # Raises the error for a pattern that isn't valid, then the values for
      # one expansion, from the mapping or the block.
      def values_for(mapping, processor, normalize_values, block)
        raise_if_invalid
        Values.new(Values.mapping_or_block(mapping, block), normalize_values,
          processor)
      end

      # Joins each node as the block writes it, into a string in the given
      # encoding. A non-ASCII node in another encoding changes the string's
      # encoding to its own.
      def render(encoding)
        result = String.new.force_encoding(encoding)
        @nodes.each { |node| result << yield(node) }
        result
      end
    end
  end
end
