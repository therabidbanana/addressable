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
    # only in how they split the URI between the varspecs. Template's private
    # methods of the same names call these.
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
      #   The value captured for each varspec, in order, and where it begins
      #   and ends, as a regular expression's MatchData gives them, with
      #   group 1 for the first varspec.
      # @param [#restore, nil] processor The processor, if any.
      #
      # @return [Addressable::Template::MatchData, NilClass]
      #   The match, or nil if the template has no expressions and the URI
      #   isn't the pattern as written.
      def self.match_data(template, uri, expansions, matched, processor)
        mapping = {}
        unparsed_values = matched.captures

        if uri.to_str == template.pattern
          return Addressable::Template::MatchData.new(uri, template, mapping)
        elsif expansions.size > 0
          index = 0
          expansions.each do |expansion|
            _, operator, varlist = *expansion.match(EXPRESSION)
            varspecs = varlist.split(',')
            varspecs.each_with_index do |varspec, position|
              _, name, modifier = *varspec.match(VARSPEC)
              mapping[name] ||= nil
              case operator
              when nil, '+', '#', '/', '.'
                unparsed_value = unparsed_values[index]
                name = varspec[VARSPEC, 1]
                value = unparsed_value
                if value && modifier == '*'
                  # Members of the default, + and # operators are joined with
                  # a comma. A member can be empty, but joiners at the end of
                  # the value can be the ones before the later variables with
                  # a value, when those start right where it ends.
                  value = value.split(JOINERS.fetch(operator, ','), -1)
                  # Right after the leader, an empty value is one empty
                  # member.
                  if value.empty? && position == 0 && LEADERS.key?(operator)
                    value = ['']
                  end
                  reached = matched.end(index + 1)
                  (1...(varspecs.size - position)).each do |ahead|
                    later = unparsed_values[index + ahead]
                    exploded = varspecs[position + ahead][VARSPEC, 2] == '*'
                    # An empty list is undefined, and has no joiner.
                    next if later.nil? || (exploded && later.empty?)
                    group = index + ahead + 1
                    break unless matched.begin(group) == reached &&
                      value.last == ''
                    value.pop
                    reached = matched.end(group)
                  end
                end
              when ';', '?', '&'
                if modifier == '*'
                  if unparsed_values[index]
                    pairs = unparsed_values[index].split(JOINERS[operator])
                    pairs = pairs.map do |pair|
                      key, val = pair.split('=', 2)
                      [key, val || ""]
                    end
                    # An exploded list repeats the variable's name, where an
                    # associative array uses its own keys.
                    if !pairs.empty? && pairs.all? { |key, _| key == name }
                      value = pairs.map { |_, val| val }
                    else
                      value = pairs.inject({}) do |acc, (key, val)|
                        acc[key] = val
                        acc
                      end
                    end
                  end
                else
                  if (unparsed_values[index])
                    name, value = unparsed_values[index].split('=')
                    value = "" if value.nil?
                  end
                end
              end
              if processor != nil && processor.respond_to?(:restore)
                value = processor.restore(name, value)
              end
              if processor == nil
                if value.is_a?(Hash)
                  value = value.inject({}){|acc, (k, v)|
                    acc[Addressable::URI.unencode_component(k)] =
                      Addressable::URI.unencode_component(v)
                    acc
                  }
                elsif value.is_a?(Array)
                  value = value.map{|v| Addressable::URI.unencode_component(v) }
                else
                  value = Addressable::URI.unencode_component(value)
                end
              end
              if !mapping.has_key?(name) || mapping[name].nil?
                # Doesn't exist, set to value (even if value is nil)
                mapping[name] = value
              end
              index = index + 1
            end
          end
          return Addressable::Template::MatchData.new(uri, template, mapping)
        else
          return nil
        end
      end
    end
  end
end
