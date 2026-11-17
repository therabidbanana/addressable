# frozen_string_literal: true

# coding: utf-8
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

require "spec_helper"

require "addressable/template"

describe Addressable::Template, "engine" do
  # Each example starts from :regexp, whatever TEMPLATE_MODE sets, and the
  # default is put back afterwards.
  around do |example|
    @default_engine = Addressable::Template.engine
    begin
      Addressable::Template.engine = :regexp
      example.run
    ensure
      Addressable::Template.engine = @default_engine
    end
  end

  describe ".engine" do
    it "defaults to :regexp, or :machine with TEMPLATE_MODE=machine" do
      expect(@default_engine).to eq(TestHelper.template_engine)
    end

    it "can be set to :machine" do
      Addressable::Template.engine = :machine
      expect(Addressable::Template.engine).to eq(:machine)
    end

    it "can be set back to :regexp" do
      Addressable::Template.engine = :machine
      Addressable::Template.engine = :regexp
      expect(Addressable::Template.engine).to eq(:regexp)
    end

    [:other, "machine", nil].each do |engine|
      it "raises ArgumentError for #{engine.inspect}" do
        expect { Addressable::Template.engine = engine }.to raise_error(
          ArgumentError, "unknown template engine: #{engine.inspect}"
        )
        expect(Addressable::Template.engine).to eq(:regexp)
      end
    end

    it "is shared with subclasses" do
      subclass = Class.new(Addressable::Template)
      subclass.engine = :machine
      expect(Addressable::Template.engine).to eq(:machine)
      expect(subclass.engine).to eq(:machine)
      expect(subclass.new("{a}").engine).to eq(:machine)
    end
  end

  describe ".new" do
    it "uses the default engine without the engine keyword" do
      expect(Addressable::Template.new("{a}").engine).to eq(:regexp)
    end

    it "uses the default engine when engine is nil" do
      Addressable::Template.engine = :machine
      template = Addressable::Template.new("{a}", engine: nil)
      expect(template.engine).to eq(:machine)
    end

    [:regexp, :machine].each do |engine|
      it "takes #{engine.inspect} as the engine keyword" do
        other = engine == :regexp ? :machine : :regexp
        Addressable::Template.engine = other
        template = Addressable::Template.new("{a}", engine: engine)
        expect(template.engine).to eq(engine)
      end
    end

    [:other, "machine"].each do |engine|
      it "raises ArgumentError for engine: #{engine.inspect}" do
        expect { Addressable::Template.new("{a}", engine: engine) }.to(
          raise_error(
            ArgumentError, "unknown template engine: #{engine.inspect}"
          )
        )
      end
    end

    it "raises ArgumentError for an unknown keyword" do
      expect { Addressable::Template.new("{a}", other: :machine) }.to(
        raise_error(ArgumentError)
      )
    end

    it "still raises TypeError for a pattern that isn't a string" do
      expect { Addressable::Template.new({}) }.to raise_error(TypeError)
    end
  end

  describe "#engine" do
    it "follows the default until the template picks its engine" do
      template = Addressable::Template.new("{a}")
      Addressable::Template.engine = :machine
      expect(template.engine).to eq(:machine)
    end

    it "keeps the engine it picked when the default changes" do
      template = Addressable::Template.new("{a}")
      expect(template.engine).to eq(:regexp)
      Addressable::Template.engine = :machine
      expect(template.engine).to eq(:regexp)
    end

    it "keeps the engine it was given when the default changes" do
      template = Addressable::Template.new("{a}", engine: :machine)
      Addressable::Template.engine = :regexp
      expect(template.engine).to eq(:machine)
    end
  end

  describe "#freeze" do
    it "picks the engine" do
      template = Addressable::Template.new("{a}").freeze
      Addressable::Template.engine = :machine
      expect(template.engine).to eq(:regexp)
    end

    it "keeps the engine it was given" do
      template = Addressable::Template.new("{a}", engine: :machine).freeze
      expect(template.engine).to eq(:machine)
    end
  end

  describe "#partial_expand" do
    it "returns a template with the same engine" do
      template = Addressable::Template.new("{a}{b}", engine: :regexp)
      Addressable::Template.engine = :machine
      partial = template.partial_expand("a" => "x")
      expect(partial.pattern).to eq("x{b}")
      expect(partial.engine).to eq(:regexp)
    end

    it "returns a template with the :machine engine from one" do
      template = Addressable::Template.new("{a}{b}", engine: :machine)
      partial = template.partial_expand("a" => "x")
      expect(partial.pattern).to eq("x{b}")
      expect(partial.engine).to eq(:machine)
    end
  end

  describe "Marshal" do
    it "keeps the engine a template was given" do
      template = Addressable::Template.new("{a}", engine: :machine)
      loaded = Marshal.load(Marshal.dump(template))
      expect(loaded).to eq(template)
      expect(loaded.engine).to eq(:machine)
    end

    it "keeps the engine a template picked" do
      template = Addressable::Template.new("{a}").freeze
      loaded = Marshal.load(Marshal.dump(template))
      Addressable::Template.engine = :machine
      expect(loaded.engine).to eq(:regexp)
    end

    it "picks an engine for a template dumped before it picked one" do
      data = Marshal.dump(Addressable::Template.new("{a}"))
      Addressable::Template.engine = :machine
      loaded = Marshal.load(data)
      expect(loaded.engine).to eq(:machine)
      expect(loaded.expand("a" => "b").to_str).to eq("b")
    end
  end

  context "with the :machine engine" do
    let(:template) do
      Addressable::Template.new("{a}/{b}", engine: :machine)
    end

    it "expands" do
      expect(template.expand("a" => "x", "b" => "y").to_str).to eq("x/y")
    end

    it "expands from a mapping that isn't a Hash" do
      expect(template.expand(lambda { |name| name.upcase }).to_str).to eq(
        "A/B"
      )
    end

    it "raises TypeError for a value that isn't a mapping" do
      expect { template.expand(42) }.to raise_error(
        TypeError, /into a mapping/
      )
    end

    it "matches" do
      expect(template.match("x/y").mapping).to eq("a" => "x", "b" => "y")
    end

    it "matches with Template's MatchData" do
      data = template.match("x/y")
      expect(data).to be_an_instance_of(Addressable::Template::MatchData)
      expect(data.template).to equal(template)
      expect(data["a"]).to eq("x")
      expect(data.to_s).to eq("x/y")
      expect(data.variables).to eq(["a", "b"])
      expect(data.values).to eq(["x", "y"])
      expect(data.to_a).to eq(["x/y", "x", "y"])
    end

    it "lists its variables, and returns a copy each time" do
      expect(template.variables).to eq(["a", "b"])
      template.variables << "c"
      expect(template.variables).to eq(["a", "b"])
      expect(template.variable_defaults).to eq({})
    end

    it "lists its variables once frozen" do
      expect(template.freeze.variables).to eq(["a", "b"])
    end

    it "extracts with its own match" do
      expect(template.extract("x/y")).to eq("a" => "x", "b" => "y")
    end

    it "matches with a processor" do
      processor = Class.new { def self.match(name) name == "a" ? "x" : nil end }
      expect(template.match("x/y", processor).mapping).to eq(
        "a" => "x", "b" => "y"
      )
    end

    it "has #named_captures" do
      expect(template.named_captures).to eq("a" => [1], "b" => [2])
    end

    it "builds the same regexp as the :regexp engine" do
      regexp = Addressable::Template.new("{a}/{b}", engine: :regexp)
      expect(template.to_regexp).to eq(regexp.to_regexp)
      expect(template.source).to eq(regexp.source)
    end

    it "freezes, and still expands and matches" do
      expect(template.freeze).to be_frozen
      expect(template.expand("a" => "x", "b" => "y").to_str).to eq("x/y")
      expect(template.match("x/y").mapping).to eq("a" => "x", "b" => "y")
    end

    it "raises a parse error from the first operation, not new or freeze" do
      invalid = Addressable::Template.new("{!a}", engine: :machine)
      expect(invalid.freeze).to be_frozen
      message = 'Invalid template operator "!" in "{!a}" at position 0'
      expect { invalid.expand({}) }.to raise_error(
        Addressable::Template::InvalidTemplateOperatorError, message
      )
      expect { invalid.match("") }.to raise_error(
        Addressable::Template::InvalidTemplateOperatorError, message
      )
    end

    it "survives a Marshal round trip after use" do
      template.expand("a" => "x", "b" => "y")
      loaded = Marshal.load(Marshal.dump(template))
      expect(loaded.engine).to eq(:machine)
      expect(loaded.expand("a" => "1", "b" => "2").to_str).to eq("1/2")
    end
  end

  describe "#== and #hash" do
    it "ignore the engine" do
      regexp = Addressable::Template.new("{a}", engine: :regexp)
      machine = Addressable::Template.new("{a}", engine: :machine)
      expect(regexp).to eq(machine)
      expect(regexp).to eql(machine)
      expect(regexp.hash).to eq(machine.hash)
    end
  end
end
