require "strscan"
require "addressable/template_machine"

module Addressable
  class TemplateLexer
    OPERATORS = {
      "/" => Addressable::TemplateMachine::OpPath,
      "?" => Addressable::TemplateMachine::OpForm,
      "&" => Addressable::TemplateMachine::OpFormContinuation,
      "#" => Addressable::TemplateMachine::OpFragment,
      "." => Addressable::TemplateMachine::OpLabel,
      ";" => Addressable::TemplateMachine::OpPathParams,
      "+" => Addressable::TemplateMachine::OpReserved,
      " " => Addressable::TemplateMachine::OpPlain,
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
          scanned = scanner.scan(Addressable::TemplateMachine::VARSPEC)
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
              curr_node << Addressable::TemplateMachine::Variable.new(
                op: op_class, name: scanner[1], prefix: scanner[3].to_i
              )
            elsif scanner[2] == "*"
              curr_node << Addressable::TemplateMachine::Variable.new(
                op: op_class, name: scanner[1], explode: true
              )
            elsif scanner[1]
              curr_node << Addressable::TemplateMachine::Variable.new(
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
