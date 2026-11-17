require "addressable/template/machine/expression"

# Written as Addressable::Template, not nested, as in machine.rb.
class Addressable::Template
  module Machine
    # Path segment expansion ({/var}).
    class OpPath < Expression
      def self.operator; "/"; end
      def self.leader; "/"; end
      def self.joiner; "/"; end
    end
  end
end
