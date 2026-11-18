# Written as Addressable::Template, not nested, as in machine.rb.
class Addressable::Template
  module Machine
    # Literal text between expressions, as the pattern writes it.
    class Literal
      attr_reader :text
      # Whether a fragment may have started before the literal, so that
      # expansion encoded a "#" in it as "%23". Set by Parser.
      attr_accessor :fragment
      # The node right after the literal, or nil at the end of the pattern.
      attr_reader :following

      def initialize(text)
        @text = text
        # Parser sets these for a valid pattern.
        @fragment = false
        @following = nil
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

      # Notes the node right after the literal. Parser calls it going back
      # from the end of the pattern.
      #
      # @param [Literal, Expression, nil] following
      #   The node after the literal, or nil at the end.
      def place_before(following)
        @following = following
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
      # @param [#match, nil] _processor Unused: a literal has no variables.
      def match_steps(matcher, _processor = nil)
        matcher.literal(Matching.literal_units(@text, fragment))
      end

      # The literal's part of Template#to_regexp, matching it as
      # match_steps does.
      def regexp_source
        Matching.literal_source(Matching.literal_units(@text, fragment))
      end

      # Literal text matches only as written, so it can't take what the
      # expression before it could match.
      def absorbs?(_previous)
        false
      end

      # Whether the text from the literal on starts with a comma.
      def comma_may_start_here?
        text.start_with?(",")
      end
    end
  end
end
