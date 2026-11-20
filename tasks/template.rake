# frozen_string_literal: true

namespace :template do
  desc "Print the states the :machine engine matches a template with. " \
    "PATTERN='{/a}{?b}' gives the template."
  task :graph do
    require "addressable/template"

    pattern = ENV.fetch("PATTERN") do
      abort "Give the template as PATTERN, such as PATTERN='{/a}{?b}'"
    end
    puts Addressable::Template::ParsedTemplate.new(pattern).matcher
  end
end
