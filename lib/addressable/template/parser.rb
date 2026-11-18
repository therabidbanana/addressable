require "strscan"
require "addressable/template/machine"
require "addressable/template/matching"

module Addressable
  class Template
    # Turns a pattern into ParsedTemplate's nodes: a Machine::Literal for
    # each run of literal text, a Machine expression for each {...}, and a
    # Machine::Invalid for each token that isn't valid. It splits the
    # pattern and checks each expression as Template#check_expressions does,
    # and never raises for an invalid one.
    #
    # For a valid pattern, it also notes on each node what matching it, or
    # writing its part of the regexp, depends on around it, so that the
    # machine splits a URI as Template's regexp does. Both engines give the
    # results in the examples.
    #
    # - fragment, on every node: whether a fragment may have started before
    #   it. A fragment can't contain "#" (RFC 3986 section 3.5), so
    #   expansion encodes every "#" after the first as "%23", and a later
    #   "#" in a literal or a # leader matches either way. "{+a}#x" matches
    #   "p#q%23x" and "p#q#x", both with a = "p#q", and "{#a}x{#b}" matches
    #   "#px%23q" and "#px#q", both with a = "p" and b = "q". Turning "%23"
    #   back into "#" before matching wouldn't do the same: a value's own
    #   "#" is encoded as "%23" too, so "#{a}" matches "#b%23c", with
    #   a = "b#c", but not "#b#c". It depends on the nodes before, so it's
    #   noted as each node is added.
    # - label_dots, on a . expression: whether its value can contain ".",
    #   which is also its leader. It can only where the text on both sides
    #   can't continue the value (Matching.label_takes_dots?): "/{.d}/"
    #   matches "/.example.com/" with d = "example.com", but in "/{.d}{e}"
    #   it can't, and "/.example.comz" gives d = nil and
    #   e = ".example.comz". It needs the literal text on both sides, so
    #   it's noted once every node is added.
    # - following and comma_may_start_here, on every node: the node after
    #   it, and whether a comma could start there. They only shape
    #   to_regexp, so it writes what Template's builder writes; matching
    #   splits the same way without them. In "{a}{b}", {b} can match
    #   anything {a} could, so {a} never takes a value ("xy" gives a = nil
    #   and b = "xy"), and the regexp writes {a}'s value after "(?!)".
    #   "{+a,b}" matches "p,q,r" with a = "p" and b = "q,r", and the regexp
    #   writes a nested, possessive form for it, which it can only use when
    #   no comma can follow, unlike in "{+a,b}," or "{+a,b}{.x},", which
    #   split "p,q,r," the same way. They depend on the nodes after, so
    #   they're noted going back from the end, once every node is added.
    #
    # @api private
    class Parser
      OPERATORS = {
        "/" => Machine::OpPath,
        "?" => Machine::OpForm,
        "&" => Machine::OpFormContinuation,
        "#" => Machine::OpFragment,
        "." => Machine::OpLabel,
        ";" => Machine::OpPathParams,
        "+" => Machine::OpReserved
      }.freeze

      # Template's tokens: literal text, an expression up to the next "}"
      # (or the end, if there's no "}"), or a "}" that doesn't close an
      # expression.
      LITERAL = /[^{}]+/
      EXPRESSION_TOKEN = /\{[^}]*\}?/
      OPEN_BRACE = /\{/
      NEXT_OPEN_BRACE = /(?=\{)/
      CLOSE_BRACE = /\}/
      COMMA = /,/
      # Template's RESERVED_OPERATORS, which RFC 6570 reserves for
      # extensions. Written out because template.rb loads this file before
      # defining it.
      RESERVED_OPERATOR = /[=,!@|]/

      def initialize
        @nodes = []
        @invalid = false
        # Whether a fragment may have started (see #add).
        @fragment = false
        # The literal text before each expression and after the last, and
        # whether a fragment may have started before each, and before each
        # expression, as Matching.label_takes_dots? takes them.
        @literals = [""]
        @either_literal = [false]
        @either_leader = []
      end

      # Parses the pattern. A Parser parses one pattern.
      #
      # @param [String] pattern The pattern.
      #
      # @return [Array] The nodes.
      def parse_nodes(pattern)
        scan(pattern)
        place_from_end unless @invalid
        @nodes
      end

      private

      # Splits the pattern into tokens, and adds a node for each.
      def scan(pattern)
        scanner = StringScanner.new(pattern)
        # Template counts positions in characters. Adding up token lengths
        # keeps that linear; StringScanner#charpos counts from the start of
        # the pattern each time, which is quadratic for non-ASCII text.
        position = 0
        until scanner.eos?
          if (literal = scanner.scan(LITERAL))
            add(Machine::Literal.new(literal))
            position += literal.length
          elsif scanner.skip(CLOSE_BRACE)
            add(Machine::Invalid.new(
              InvalidTemplateError, "Unmatched \"}\" at position #{position}",
              []
            ))
            position += 1
          else
            start = scanner.pos
            if (node = expression(scanner))
              # A valid expression is ASCII, so its bytes are its
              # characters: everything expression reads with (OPEN_BRACE,
              # OPERATORS' keys, Machine::VARSPEC, COMMA, CLOSE_BRACE)
              # matches only ASCII, and in Ruby \d is ASCII digits only.
              # RFC 6570 section 2.3 writes a non-ASCII name pct-encoded.
              position += scanner.pos - start
            else
              # Go back and take Template's token for the error message.
              scanner.pos = start
              token = scanner.scan(EXPRESSION_TOKEN)
              node = invalid_token(token, position)
              position += token.length
            end
            add(node)
          end
        end
      end

      # Adds the node, noting whether a fragment may have started before
      # it, which it may at a "#" in a literal or at a + or # expression,
      # and what label_dots needs from it. Nothing walks the nodes of a
      # pattern with an invalid token, so nothing is noted from the first
      # one on.
      def add(node)
        @nodes << node
        @invalid ||= node.is_a?(Machine::Invalid)
        return if @invalid
        node.fragment = @fragment
        if node.is_a?(Machine::Literal)
          @literals[-1] += node.text
          @fragment ||= node.text.include?("#")
        else
          @either_leader << @fragment
          @fragment ||= node.class.allows_reserved?
          @literals << ""
          @either_literal << @fragment
        end
      end

      # Once every node is added: following and comma_may_start_here, going
      # back from the end, so the node after each one is already placed
      # (see #place_before on the nodes), then label_dots.
      def place_from_end
        following = nil
        @nodes.reverse_each do |node|
          node.place_before(following)
          following = node
        end

        # Only a . expression's value can take dots.
        expressions = @nodes.grep(Machine::Expression)
        return unless expressions.any? { |node| node.is_a?(Machine::OpLabel) }
        texts = expressions.map(&:text)
        expressions.each_with_index do |expression, index|
          next unless expression.is_a?(Machine::OpLabel)
          expression.label_dots = Matching.label_takes_dots?(
            index, texts, @literals, @either_leader, @either_literal
          )
        end
      end

      # Reads a valid expression at the scanner's "{", or returns nil,
      # leaving the scanner wherever it stopped.
      def expression(scanner)
        reserved, node = read_expression(scanner)
        node unless reserved
      end

      # Reads an expression at the scanner's "{": an operator, which may be
      # one RFC 6570 reserves, and varspecs up to "}". Returns whether the
      # operator is reserved, and the node, or nil, leaving the scanner
      # wherever it stopped, if the text doesn't fit.
      def read_expression(scanner)
        scanner.skip(OPEN_BRACE)
        reserved = false
        if scanner.skip(RESERVED_OPERATOR)
          reserved = true
          op_class = Machine::OpPlain
        elsif (op_class = OPERATORS[scanner.peek(1)])
          scanner.pos += 1
        else
          op_class = Machine::OpPlain
        end
        variables = []
        loop do
          # Machine's VARSPEC, not Template's.
          return nil unless scanner.scan(Machine::VARSPEC)
          variables << variable(op_class, scanner)
          if scanner.skip(CLOSE_BRACE)
            return [reserved, op_class.new(variables)]
          end
          return nil unless scanner.skip(COMMA)
        end
      end

      # The names Template#variables lists for an invalid token that ends
      # in "}". Template scans the whole pattern for expressions, and that
      # scan finds at most one in such a token: the one from the leftmost
      # "{" that reads to the token's "}". Its names are left out if its
      # operator is reserved. A try stops at the next "{" at the latest, so
      # this is linear.
      def names_in_invalid_token(token)
        scanner = StringScanner.new(token)
        while scanner.skip_until(NEXT_OPEN_BRACE)
          start = scanner.pos
          reserved, node = read_expression(scanner)
          return reserved ? [] : node.variables.map(&:name) if node
          scanner.pos = start + 1
        end
        []
      end

      def variable(op_class, scanner)
        if scanner[3]
          Machine::Variable.new(
            op: op_class, name: scanner[1], prefix: scanner[3].to_i
          )
        else
          Machine::Variable.new(
            op: op_class, name: scanner[1], explode: scanner[2] == "*"
          )
        end
      end

      def invalid_token(token, position)
        if !token.end_with?("}")
          return Machine::Invalid.new(
            InvalidTemplateError,
            "Unclosed template expression #{token.inspect} " \
            "at position #{position}",
            []
          )
        end
        names = names_in_invalid_token(token)
        if RESERVED_OPERATORS.include?(token[1])
          Machine::Invalid.new(
            InvalidTemplateOperatorError,
            "Invalid template operator #{token[1].inspect} in " \
            "#{token.inspect} at position #{position}",
            names
          )
        else
          Machine::Invalid.new(
            InvalidTemplateError,
            "Invalid template expression #{token.inspect} " \
            "at position #{position}",
            names
          )
        end
      end
    end
  end
end
