require "strscan"
require "addressable/template/machine"

# Written as Addressable::Template, not nested, so the body keeps its
# indentation from before the move.
class Addressable::Template
  # Turns a pattern into ParsedTemplate's nodes: literal strings, and a
  # Machine expression for each {...}.
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
      "+" => Machine::OpReserved,
      " " => Machine::OpPlain,
    }.freeze

    def initialize
    end

    def parse_nodes(uri_template)
      node_list = []
      curr_node = []
      lex_state = :plain
      scanner = StringScanner.new(uri_template)
      until scanner.eos?
        if lex_state == :plain
          curr_node = []
          op_class = nil
          if scanner.check_until(/{/)
            scanned = scanner.scan_until(/{/).chomp('{')
            node_list << scanned unless scanned == ""
            lex_state = :expression
          else
            node_list << scanner.rest
            scanner.terminate
          end
        elsif lex_state == :expression
          case scanner.peek(1)
          when '?', '/', '#', ';', '.', '+', '&'
            op = scanner.getch
            op_class = OPERATORS[op]
          else
            op_class = OPERATORS[' ']
          end
          lex_state = :varspec
        elsif lex_state == :varspec
          # Machine's VARSPEC, not Template's.
          scanned = scanner.scan(Machine::VARSPEC)
          if scanned.nil?
            case scanner.getch
            when ","
              # Continue pulling varspecs
            when "}"
              lex_state = :plain
              node_list << op_class.new(curr_node)
              curr_node = []
              op_class = nil
            else
              raise "Incomplete varspec"
            end
          else
            if scanner[3] && scanner[3] != ""
              curr_node << Machine::Variable.new(
                op: op_class, name: scanner[1], prefix: scanner[3].to_i
              )
            elsif scanner[2] == "*"
              curr_node << Machine::Variable.new(
                op: op_class, name: scanner[1], explode: true
              )
            elsif scanner[1]
              curr_node << Machine::Variable.new(
                op: op_class, name: scanner[1]
              )
            end
          end
        end
      end
      node_list
    end
  end
end
