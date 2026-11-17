# Written as Addressable::Template, not nested, as in machine.rb.
class Addressable::Template
  module Machine
    # Literal text between expressions, as the pattern writes it.
    class Literal
      attr_reader :text

      def initialize(text)
        @text = text
        # Expansion pct-encodes non-ASCII literals (RFC 6570 section 3.1),
        # and they don't change between calls, so they're encoded once.
        @expansion =
          if text.ascii_only?
            text
          else
            Addressable::URI.encode_component(text, LITERAL_ENCODE)
          end
      end

      def variables
        []
      end

      # The text in an expanded URI, with non-ASCII characters pct-encoded.
      # A pattern that isn't UTF-8 has its bytes encoded as they are.
      def expand(_values)
        @expansion
      end

      # The text in a partially expanded pattern: as written, since expand
      # encodes it later.
      def partial_expand(_values)
        @text
      end

      ##
      # Adds the steps that match the literal to the matcher (see
      # Matching.literal_units).
      #
      # @param [Matcher] matcher The matcher.
      # @param [TrueClass, FalseClass] fragment
      #   Whether a fragment may have started before the literal.
      def match_steps(matcher, fragment)
        matcher.literal(Matching.literal_units(@text, fragment))
      end

      # The literal's part of Template#to_regexp, matching it as
      # match_steps does.
      #
      # @param [TrueClass, FalseClass] fragment
      #   Whether a fragment may have started before the literal.
      def regexp_source(fragment, _label_dots, _following, _comma_follows)
        Matching.literal_source(Matching.literal_units(@text, fragment))
      end
    end
  end
end
