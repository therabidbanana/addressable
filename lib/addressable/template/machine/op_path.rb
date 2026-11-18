require "addressable/template/machine/expression"

module Addressable
  class Template
    module Machine
      # Path segment expansion ({/var}).
      class OpPath < Expression
        def self.operator; "/"; end
        def self.leader; "/"; end
        def self.joiner; "/"; end
      end
    end
  end
end
