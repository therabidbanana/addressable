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
        search =
          if processor.respond_to?(:match)
            build_matcher(processor)
          else
            matcher
          end
        # A nil URI raises NoMethodError here, as it does in Template.
        captures = search.match(uri.to_str)
        return nil unless captures
        Matching.match_data(@template, uri, search.expansions, captures,
          processor)
      end

      # Builds the matcher and the regexp, as Template#freeze builds its
      # regexp, so a frozen template can still give them. A pattern that
      # isn't valid has neither, and freezing it doesn't raise.
      def freeze
        unless @invalid
          @matcher ||= build_matcher
          @regexp ||= build_regexp
        end
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

      # The regexp Template's builder writes, from the nodes, built on first
      # use or by freeze.
      def to_regexp
        nodes
        @regexp ||= build_regexp
      end

      private

      # Renders the nodes as the regexp's source. It starts as UTF-8, as
      # the builder's does, and takes the encoding of the pattern's
      # non-ASCII literals.
      def build_regexp
        place_nodes
        result = render(Encoding::UTF_8, &:regexp_source)
        Regexp.new("\\A#{result}\\z")
      end

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
      # patterns, if any.
      def build_matcher(processor = nil)
        place_nodes
        matcher = Matcher.new(expression_texts)
        @nodes.each { |node| node.match_steps(matcher, processor) }
        matcher.finish
      end

      # The second step of building the machine, after Lexer makes the
      # nodes: notes on each node what matching it, or writing its part of
      # the regexp, depends on around it. Done once, before the first
      # matcher or regexp is built, since expansion doesn't need it; freeze
      # builds both, so a frozen template's nodes are already placed.
      # Whether a fragment may have started is worked out going forward,
      # and what follows each expression going back from the end.
      def place_nodes
        return if @placed
        note_fragments_and_label_dots
        note_followers
        @placed = true
      end

      # Notes whether a fragment may have started before each node, and,
      # for each expression, whether a label's value can contain "."
      # (Matching.label_takes_dots?, which Template uses too). A fragment
      # may start at a "#" in a literal or at a + or # expression, and from
      # then on expansion encodes a later "#", so later literals and
      # fragment leaders match it either way, as in Template's regexp.
      def note_fragments_and_label_dots
        # The literal text before each expression and after the last, and
        # whether a fragment may have started before each, and before each
        # expression, as Matching.label_takes_dots? takes them.
        literals = [""]
        either_literal = [false]
        either_leader = []
        fragment = false
        @nodes.each do |node|
          node.fragment = fragment
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

        texts = expression_texts
        @nodes.grep(Machine::Expression).each_with_index do |expression, index|
          expression.label_dots = Matching.label_takes_dots?(
            index, texts, literals, either_leader, either_literal
          )
        end
      end

      # Notes, for each expression, the expression right after it, if no
      # literal text comes between them, and whether the text after it
      # could start with a comma. Expressions can match nothing, so that
      # looks past any that can't start with one.
      def note_followers
        following = nil
        comma_follows = false
        @nodes.reverse_each do |node|
          if node.is_a?(Machine::Literal)
            following = nil
            comma_follows = node.text.start_with?(",")
          else
            node.following = following
            node.comma_follows = comma_follows
            following = node
            comma_follows ||= node.may_start_with_comma?
          end
        end
      end

      # Each expression as the pattern writes it, in order.
      def expression_texts
        @nodes.grep(Machine::Expression).map(&:text)
      end

      # Raises the error for a pattern that isn't valid, then the values for
      # one expansion, from the mapping or the block.
      def values_for(mapping, processor, normalize_values, block)
        nodes
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
