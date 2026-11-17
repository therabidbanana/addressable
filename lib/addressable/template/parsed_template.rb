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
require "addressable/template/matcher"
require "addressable/template/matching"

module Addressable
  class Template
    # The :machine engine. A Template whose engine is :machine hands its
    # operations to its own ParsedTemplate, which parses the pattern once
    # into literal and expression nodes (see Lexer and Machine), then
    # expands and matches by walking those nodes instead of building a
    # regular expression. Only Template#to_regexp and #source build one,
    # with Template's builder, when they're called.
    #
    # @api private
    class ParsedTemplate
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

      # Matches the URI as Template#match does: the nodes' steps split it
      # between the varspecs as Template's regexp would, and
      # Matching.match_data turns what each varspec captured into the
      # mapping.
      #
      # A processor's match method can give a variable's value a pattern of
      # its own, and is asked on every call, so a matcher with its patterns
      # is built for the call, as Template builds its regexp. A processor
      # that only restores values uses the template's matcher.
      def match(uri, processor)
        nodes
        uri = Matching.parse_uri(uri)
        return nil if uri == false
        matcher =
          if processor.respond_to?(:match)
            build_matcher(processor)
          else
            self.matcher
          end
        # A nil URI raises NoMethodError here, as it does in Template.
        captures = matcher.match(uri.to_str)
        return nil unless captures
        Matching.match_data(@template, uri, matcher.expansions, captures,
          processor)
      end

      # Builds the matcher, so a frozen template doesn't build it on every
      # match, as Template#freeze builds its regexp. A pattern that isn't
      # valid has none, and freezing it doesn't raise.
      def freeze
        @matcher ||= build_matcher unless @invalid
        super
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

      # Maps each variable name to the positions of its varspecs, counting
      # every varspec in the pattern from 1, as Template's regexp numbers its
      # groups: one per varspec, in order. Names are as the pattern writes
      # them, not Template's group names.
      def named_captures
        captures = {}
        position = 0
        nodes.grep(Machine::Expression).each do |expression|
          expression.variables.each do |variable|
            position += 1
            (captures[variable.name] ||= []) << position
          end
        end
        captures
      end

      private

      # The pattern's literals and expressions, or Template's error for its
      # first invalid token.
      def nodes
        raise @invalid.error_class, @invalid.message if @invalid
        @nodes
      end

      # The matcher for the pattern, built on first use.
      def matcher
        @matcher || (frozen? ? build_matcher : @matcher = build_matcher)
      end

      # Adds each node's steps to a new matcher, with the processor's
      # patterns, if any. A fragment may start at a "#" in a literal or at a
      # + or # expression, and from then on expansion encodes a later "#",
      # so later literals and fragment leaders match it either way, as in
      # Template's regexp.
      def build_matcher(processor = nil)
        texts = @nodes.grep(Machine::Expression).map(&:text)
        # The literal text before each expression and after the last, and
        # whether a fragment may have started before each.
        literals = [""]
        either_literal = [false]
        either_leader = []
        fragment = false
        @nodes.each do |node|
          if node.is_a?(Machine::Literal)
            literals[-1] += node.text
            fragment ||= node.text.include?("#")
          else
            either_leader << fragment
            fragment ||= node.class.allows_reserved?
            literals << ""
            either_literal << fragment
          end
        end

        matcher = Matcher.new(texts)
        fragment = false
        index = 0
        @nodes.each do |node|
          if node.is_a?(Machine::Literal)
            node.match_steps(matcher, fragment)
            fragment ||= node.text.include?("#")
          else
            label_dots = Matching.label_takes_dots?(
              index, texts, literals, either_leader, either_literal
            )
            node.match_steps(matcher, either_leader[index], label_dots,
              processor)
            fragment ||= node.class.allows_reserved?
            index += 1
          end
        end
        matcher.finish
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
    end
  end
end
