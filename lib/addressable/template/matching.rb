# frozen_string_literal: true

#--
# Copyright (C) Bob Aman
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

module Addressable
  class Template
    # What both engines' #match share: reading the URI, and turning the
    # values captured for each varspec into a MatchData. The engines differ
    # only in how they split the URI between the varspecs.
    #
    # @api private
    class Matching
      ##
      # Whether a URI's text is valid UTF-8, read as UTF-8 whatever its
      # encoding, as Addressable::URI reads it.
      #
      # @param [Addressable::URI, #to_str] uri The URI.
      #
      # @return [TrueClass, FalseClass]
      def self.valid_utf8?(uri)
        return true unless uri.respond_to?(:to_str)
        text = uri.to_str
        text = text.dup.force_encoding(Encoding::UTF_8) unless
          text.encoding == Encoding::UTF_8
        text.valid_encoding?
      end

      ##
      # The URI to match, or false if it can't match any template.
      # Addressable::URI.parse gives nil for nil, which is returned as it is,
      # so #match raises NoMethodError for it as it always has.
      #
      # @param [Addressable::URI, #to_str] uri The URI.
      #
      # @return [Addressable::URI, NilClass, FalseClass]
      def self.parse_uri(uri)
        # Text that isn't valid UTF-8 isn't a valid URI or IRI, so it doesn't
        # match.
        return false unless valid_utf8?(uri)
        return uri if uri.is_a?(Addressable::URI)
        Addressable::URI.parse(uri)
      rescue Addressable::URI::InvalidURIError
        # Per the documented contract, match returns nil for any input that
        # doesn't match the template - including a string that isn't even a
        # valid URI.
        false
      end

      ##
      # Splits literal text into units of [raw, encoded]: text that matches
      # as it is (raw), or with ASCII letters in either case (encoded), as
      # Matcher::Unit reads them. A non-ASCII character, written as it is or
      # as pct-encoded UTF-8, matches either way, since expansion pct-encodes
      # it (RFC 6570 section 3.1). So does a "#" that expansion may have
      # encoded because a fragment had already started. A run of pct-encoded
      # octets that isn't UTF-8 matches in either case, and anything else
      # only as written.
      #
      # @param [String] literal The literal text.
      # @param [TrueClass, FalseClass] fragment
      #   Whether a fragment may have started before the literal.
      #
      # @return [Array<Array>] The units.
      def self.literal_units(literal, fragment)
        units = []
        literal.scan(LITERAL_TOKEN) do |token|
          if token == '#'
            units << (fragment ? ['#', '%23'] : ['#', nil])
            fragment = true
          elsif token =~ LITERAL_ENCODE
            token.each_char { |character| units << either_form(character) }
          elsif token =~ /\A%[89A-Fa-f]/
            # Octets from %80 up, which LITERAL_TOKEN takes as one run: the
            # UTF-8 bytes of non-ASCII characters, if they're valid. %00 to
            # %7F are ASCII, and match only as written.
            decoded = Addressable::URI.unencode_component(token).dup
            decoded.force_encoding(Encoding::UTF_8)
            if decoded.valid_encoding?
              decoded.each_char { |character| units << either_form(character) }
            else
              units << [nil, token]
            end
          else
            units << [token, nil]
          end
        end
        units
      end

      ##
      # The regular expression source for a literal's units.
      #
      # @param [Array<Array>] units The units, from literal_units.
      #
      # @return [String] The regular expression source.
      def self.literal_regexp_source(units)
        units.map do |raw, encoded|
          if raw == '#' && encoded
            NUMBER_SIGN_EITHER_FORM
          elsif encoded.nil?
            Regexp.escape(raw)
          elsif raw.nil?
            "(?i:#{Regexp.escape(encoded)})"
          else
            "(?:#{Regexp.escape(raw)}|(?i:#{encoded}))"
          end
        end.join
      end

      ##
      # The name of the regular expression group for a variable. A group name
      # can't start with a digit, which a variable name can (RFC 6570 section
      # 2.3), so such a name gets a leading ".". No variable name starts with
      # ".", so this can't collide with another variable's group. Ruby 2.3 and
      # earlier only allow a letter or "_" as the first character, so there a
      # name that starts with a digit or a pct-encoded triplet is wrapped in
      # "__" instead.
      #
      # @param [String] name The variable name.
      #
      # @return [String] The group name.
      def self.capture_name(name)
        if GROUP_NAME_CAN_START_WITH_DOT
          name =~ /\A[0-9]/ ? ".#{name}" : name
        else
          name =~ /\A[A-Za-z_]/ ? name : "__#{name}__"
        end
      end

      # A non-ASCII character, as it is and pct-encoded.
      def self.either_form(character)
        encoded = Addressable::URI.encode_component(character, LITERAL_ENCODE)
        [character, encoded]
      end
      private_class_method :either_form

      ##
      # Whether a label expression's value can contain ".". Label expansion
      # leaves a "." in a value as it is (RFC 6570 section 3.2.5), so where
      # the value ends is only known where the expression is delimited by
      # the start or end of the URI or by characters that can't be part of
      # its expansion (section 1.4): a lone, unexploded variable, with a
      # reserved character in the literal text since the previous
      # expression, and a reserved character next, after any expressions
      # that start with one when they aren't empty. A "#" counts only if a
      # fragment can't have started before it, since expansion encodes a
      # later one as "%23".
      #
      # @param [Integer] index The expression's index.
      # @param [Array<String>] expressions The pattern's expressions.
      # @param [Array<String>] literals
      #   The literal text before each expression, and after the last one.
      # @param [Array<TrueClass, FalseClass>] either_leader
      #   Whether a fragment may have started before each expression.
      # @param [Array<TrueClass, FalseClass>] either_literal
      #   Whether a fragment may have started before each literal.
      #
      # @return [TrueClass, FalseClass]
      def self.label_takes_dots?(index, expressions, literals, either_leader,
                                 either_literal)
        _, operator, varlist = *expressions[index].match(EXPRESSION)
        return false unless operator == '.' && varlist =~ VARSPEC && $2 != '*'
        return false unless index == 0 || literals[index] =~ LABEL_DELIMITER
        position = index + 1
        while position < expressions.size && literals[position].empty?
          operator = expressions[position][1]
          return false unless "/?&;".include?(operator) ||
            (operator == '#' && !either_leader[position])
          position += 1
        end
        literal = literals[position]
        return true if literal.empty?
        literal[0] =~ LABEL_DELIMITER &&
          !(literal[0] == '#' && either_literal[position]) ? true : false
      end

      ##
      # The MatchData for a URI that the template matched.
      #
      # @param [Addressable::Template] template The template.
      # @param [Addressable::URI] uri The URI, from parse_uri.
      # @param [Array<String>] expansions The template's expressions, in order.
      # @param [#captures, #begin, #end] matched
      #   The value captured for each varspec, in order, as a regular
      #   expression's MatchData gives them. Without joiners_required, it
      #   also needs where each one begins and ends, with group 1 for the
      #   first varspec.
      # @param [#restore, nil] processor The processor, if any.
      # @param [TrueClass, FalseClass] joiners_required
      #   Whether every value captured came after its leader or joiner, as
      #   the :machine engine matches them. :regexp's regexp makes joiners
      #   optional, so there an empty exploded value after the first
      #   varspec can be a joiner that a later value started after, and has
      #   no members.
      #
      # @return [Addressable::Template::MatchData, NilClass]
      #   The match, or nil if the template has no expressions and the URI
      #   isn't the pattern as written.
      def self.match_data(template, uri, expansions, matched, processor,
                          joiners_required: false)
        mapping = {}
        if uri.to_str == template.pattern
          return Addressable::Template::MatchData.new(uri, template, mapping)
        end
        return nil if expansions.empty?

        captured = matched.captures
        index = 0
        # The names whose value so far is a prefix's.
        prefixed = {}
        expansions.each do |expansion|
          _, operator, varlist = *expansion.match(EXPRESSION)
          varspecs = varlist.split(',')
          varspecs.each_with_index do |varspec, position|
            _, name, modifier = *varspec.match(VARSPEC)
            # Every varspec's name is in the mapping, even without a value.
            mapping[name] ||= nil
            value = captured[index]
            case operator
            when nil, '+', '#', '/', '.'
              if value && modifier == '*' && joiners_required
                # An empty value came after its leader or joiner, so it's
                # one empty member.
                value = value.split(JOINERS.fetch(operator, ','), -1)
                value = [''] if value.empty?
              elsif value && modifier == '*'
                value = exploded_members(operator, value, position == 0)
                drop_joiners_before_later_values(value,
                  varspecs.drop(position + 1), captured, matched, index + 1)
              end
            when ';', '?', '&'
              if value && modifier == '*' && joiners_required
                # Every member came after its leader or joiner, so an empty
                # one is an empty name, which expansion writes for a ""
                # key. :regexp drops it, or gives it a nil key.
                value = named_members(operator, name, value, true)
              else
                name, value = named_value(operator, name, modifier == '*', value)
              end
            end
            value = restore(name, value, processor)
            # A name that appears again keeps its first value, unless that
            # was nil. On the machine, which checks that a prefix's value is
            # the start of the whole one, the whole value replaces it:
            # {/var:1,var} gives "/v/value" var "value".
            prefix = !modifier.nil? && modifier.start_with?(':')
            if mapping[name].nil? ||
                (joiners_required && prefixed[name] && !prefix && !value.nil?)
              mapping[name] = value
              prefixed[name] = prefix
            end
            index += 1
          end
        end
        Addressable::Template::MatchData.new(uri, template, mapping)
      end

      ##
      # An exploded value's members, for a default, +, #, / or .
      # expression. A member can be empty.
      #
      # @param [String] operator The expression's operator, or nil.
      # @param [String] value The value captured for the varspec.
      # @param [TrueClass, FalseClass] first
      #   Whether the varspec is the expression's first.
      #
      # @return [Array<String>] The members.
      def self.exploded_members(operator, value, first)
        members = value.split(JOINERS.fetch(operator, ','), -1)
        # Right after the leader, an empty value is one empty member.
        members = [''] if members.empty? && first && LEADERS.key?(operator)
        members
      end
      private_class_method :exploded_members

      ##
      # Removes the empty members at the end of an exploded value that are
      # really the joiners before later varspecs' values in the same
      # expression: one for each later value that starts right where the
      # value, or the later value before it, ends.
      #
      # @param [Array<String>] members The value's members, changed in place.
      # @param [Array<String>] later_varspecs
      #   The varspecs after the value's in its expression.
      # @param [Array<String, nil>] captured The value captured for each
      #   varspec, in order.
      # @param [#begin, #end] matched Where each group begins and ends.
      # @param [Integer] group The value's group, 1 for the first varspec.
      def self.drop_joiners_before_later_values(members, later_varspecs,
                                                captured, matched, group)
        reached = matched.end(group)
        later_varspecs.each_with_index do |varspec, offset|
          later_group = group + offset + 1
          later = captured[later_group - 1]
          # An empty list is undefined, and has no joiner.
          next if later.nil? || (varspec[VARSPEC, 2] == '*' && later.empty?)
          break unless matched.begin(later_group) == reached &&
            members.last == ''
          members.pop
          reached = matched.end(later_group)
        end
      end
      private_class_method :drop_joiners_before_later_values

      ##
      # A ;, ? or & expression's value, and the name it goes in the mapping
      # under.
      #
      # @param [String] operator The expression's operator.
      # @param [String] name The varspec's name.
      # @param [TrueClass, FalseClass] exploded Whether the varspec is.
      # @param [String, nil] value The value captured for the varspec.
      #
      # @return [Array] The name and the value.
      def self.named_value(operator, name, exploded, value)
        if value.nil?
          [name, nil]
        elsif exploded
          [name, named_members(operator, name, value)]
        else
          # The name is the one the URI gives, which may not be the
          # varspec's.
          uri_name, value = value.split('=')
          [uri_name, value || ""]
        end
      end
      private_class_method :named_value

      ##
      # An exploded ;, ? or & value's key=value pairs: a list if every key
      # is the variable's name, as an exploded list repeats it, and an
      # associative array otherwise.
      #
      # @param [String] operator The expression's operator.
      # @param [String] name The varspec's name.
      # @param [String] value The value captured for the varspec.
      # @param [TrueClass, FalseClass] keep_empty
      #   Whether an empty member is an empty name, rather than dropped at
      #   the end or a nil key elsewhere, as :regexp gives it.
      #
      # @return [Array<String>, Hash] The list or associative array.
      def self.named_members(operator, name, value, keep_empty = false)
        members = value.split(JOINERS[operator], keep_empty ? -1 : 0)
        members = [''] if keep_empty && members.empty?
        pairs = members.map do |pair|
          key, member = pair.split('=', 2)
          [keep_empty ? key.to_s : key, member || ""]
        end
        if !pairs.empty? && pairs.all? { |key, _| key == name }
          pairs.map { |_, member| member }
        else
          Hash[pairs]
        end
      end
      private_class_method :named_members

      ##
      # The value as the processor restores it, or pct-decoded when there's
      # no processor. A processor without a restore method leaves it as it
      # is.
      #
      # @param [String] name The name the value goes under.
      # @param [String, Array, Hash, nil] value The value.
      # @param [#restore, nil] processor The processor, if any.
      #
      # @return [Object] The restored value.
      def self.restore(name, value, processor)
        if processor.nil?
          decode(value)
        elsif processor.respond_to?(:restore)
          processor.restore(name, value)
        else
          value
        end
      end
      private_class_method :restore

      # A value with its pct-encoded triplets decoded, and an associative
      # array's keys as well.
      def self.decode(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, member), decoded|
            decoded[Addressable::URI.unencode_component(key)] =
              Addressable::URI.unencode_component(member)
          end
        when Array
          value.map { |member| Addressable::URI.unencode_component(member) }
        else
          Addressable::URI.unencode_component(value)
        end
      end
      private_class_method :decode
    end
  end
end
