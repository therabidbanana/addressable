module Addressable
  class Template
    module Machine
      # A varspec: a variable's name, its modifier, and its expression's
      # operator class.
      class Variable
        attr_reader :op, :name, :explode, :prefix

        def initialize(op:, name:, explode: false, prefix: nil)
          @op = op
          @name = name
          @explode = explode
          @prefix = prefix
        end

        # The varspec as the pattern wrote it. VARSPEC allows no leading
        # zero in a prefix, so the number reads back the same.
        def pattern_text
          if @prefix
            "#{name}:#{@prefix}"
          elsif @explode
            "#{name}*"
          else
            name
          end
        end

        # Whether its operator keeps reserved characters and pct-encoded
        # triplets (+ and #). Values#expand encodes by this.
        def allows_reserved?
          @op.allows_reserved?
        end

        ##
        # Tags an expanded value for joining into its expression, as its
        # operator joins values.
        #
        # @param [String, Array] value The value from Values#expand.
        # @param [TrueClass, FalseClass, nil] keypairs
        #   Whether an array holds key=value pairs.
        # @param [TrueClass, FalseClass] composite
        #   Whether the value was a list or associative array before it was
        #   expanded.
        #
        # @return [TaggedValue] The tagged value.
        def tag(value, keypairs, composite)
          op.tagged_value.new(name, value, keypairs, composite)
        end
      end
    end
  end
end
