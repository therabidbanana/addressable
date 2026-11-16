require "strscan"
require "addressable/template/machine"

# Written as Addressable::Template, not nested, so the body keeps its
# indentation from before the move.
class Addressable::Template
  # Turns a pattern into ParsedTemplate's nodes: literal strings, a Machine
  # expression for each {...}, and a Machine::Invalid for each token that
  # isn't valid. It splits the pattern and checks each expression as
  # Template#check_expressions does, and never raises for an invalid one.
  #
  # @api private
  class Lexer
    OPERATORS = {
      "/" => Machine::OpPath,
      "?" => Machine::OpForm,
      "&" => Machine::OpFormContinuation,
      "#" => Machine::OpFragment,
      "." => Machine::OpLabel,
      ";" => Machine::OpPathParams,
      "+" => Machine::OpReserved
    }.freeze

    # Template's tokens: literal text, an expression up to the next "}" (or
    # the end, if there's no "}"), or a "}" that doesn't close an
    # expression.
    LITERAL = /[^{}]+/
    EXPRESSION_TOKEN = /\{[^}]*\}?/
    OPEN_BRACE = /\{/
    NEXT_OPEN_BRACE = /(?=\{)/
    CLOSE_BRACE = /\}/
    COMMA = /,/
    # Template's RESERVED_OPERATORS, which RFC 6570 reserves for extensions.
    # Written out because template.rb loads this file before defining it.
    RESERVED_OPERATOR = /[=,!@|]/

    def parse_nodes(pattern)
      nodes = []
      scanner = StringScanner.new(pattern)
      # Template counts positions in characters. Adding up token lengths
      # keeps that linear; StringScanner#charpos counts from the start of
      # the pattern each time, which is quadratic for non-ASCII text.
      position = 0
      until scanner.eos?
        if (literal = scanner.scan(LITERAL))
          nodes << literal
          position += literal.length
        elsif scanner.skip(CLOSE_BRACE)
          nodes << Machine::Invalid.new(
            InvalidTemplateError, "Unmatched \"}\" at position #{position}",
            []
          )
          position += 1
        else
          start = scanner.pos
          if (node = expression(scanner))
            # A valid expression is ASCII, so its bytes are its characters:
            # everything expression reads with (OPEN_BRACE, OPERATORS'
            # keys, Machine::VARSPEC, COMMA, CLOSE_BRACE) matches only ASCII,
            # and in Ruby \d is ASCII digits only. RFC 6570 section 2.3
            # writes a non-ASCII name pct-encoded.
            position += scanner.pos - start
          else
            # Go back and take Template's token for the error message.
            scanner.pos = start
            token = scanner.scan(EXPRESSION_TOKEN)
            node = invalid_token(token, position)
            position += token.length
          end
          nodes << node
        end
      end
      nodes
    end

    private

    # Reads a valid expression at the scanner's "{", or returns nil, leaving
    # the scanner wherever it stopped.
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
        return [reserved, op_class.new(variables)] if scanner.skip(CLOSE_BRACE)
        return nil unless scanner.skip(COMMA)
      end
    end

    # The names Template#variables lists for an invalid token that ends in
    # "}". Template scans the whole pattern for expressions, and that scan
    # finds at most one in such a token: the one from the leftmost "{" that
    # reads to the token's "}". Its names are left out if its operator is
    # reserved. A try stops at the next "{" at the latest, so this is
    # linear.
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
