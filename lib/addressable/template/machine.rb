require "addressable/uri"
require "addressable/template/values"
require "addressable/template/machine/literal"
require "addressable/template/machine/variable"
require "addressable/template/machine/tagged_value"
require "addressable/template/machine/expression"
require "addressable/template/machine/op_plain"
require "addressable/template/machine/op_reserved"
require "addressable/template/machine/op_path"
require "addressable/template/machine/op_label"
require "addressable/template/machine/op_path_params"
require "addressable/template/machine/op_form"

# Written as Addressable::Template, not nested, so the body keeps its
# indentation from before the move. The files in machine/ do the same.
class Addressable::Template
  # The :machine engine's nodes: a Literal for literal text, a Variable for
  # each varspec, and an Expression subclass for each operator, each in
  # its own file in machine/. Parser builds them and ParsedTemplate walks
  # them. Each node can expand, add the steps that match it to a Matcher,
  # and write its part of Template#to_regexp.
  #
  # As it builds them, Parser notes on each node what matching it depends
  # on around it: whether a fragment may have started before it, the node
  # right after it, and, for an expression, whether a label's value can
  # contain "." and whether a comma could start at it. Parser's comment
  # explains each, with examples.
  #
  # @api private
  module Machine
    variable_char_class =
      Addressable::URI::CharacterClasses::ALPHA +
      Addressable::URI::CharacterClasses::DIGIT + '_'

    # Atomic, as in Template, so a long name can't backtrack.
    var_char =
      "(?>(?:[#{variable_char_class}]|%[a-fA-F0-9][a-fA-F0-9])+)"

    variable =
      "(?:#{var_char}(?:\\.?#{var_char})*)"
    varspec =
      "(?:(#{variable})(\\*|:([1-9]\\d{0,3}))?)"
    VARSPEC = /#{varspec}/

    # A token that isn't valid: the error Template raises for it, which
    # ParsedTemplate raises from the first operation that needs a valid
    # pattern, and the names Template#variables still finds in it.
    Invalid = Struct.new(:error_class, :message, :names)
  end
end
