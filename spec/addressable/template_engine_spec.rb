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
  around do |example|
    default = Addressable::Template.engine
    begin
      example.run
    ensure
      Addressable::Template.engine = default
    end
  end

  describe ".engine" do
    it "defaults to :regexp" do
      expect(Addressable::Template.engine).to eq(:regexp)
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
    [:regexp, :machine].each do |engine|
      it "returns a template with the #{engine.inspect} engine" do
        template = Addressable::Template.new("{a}{b}", engine: engine)
        Addressable::Template.engine = engine == :regexp ? :machine : :regexp
        partial = template.partial_expand("a" => "x")
        expect(partial.pattern).to eq("x{b}")
        expect(partial.engine).to eq(engine)
      end
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
