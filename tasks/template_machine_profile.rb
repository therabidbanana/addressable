# frozen_string_literal: true

require "benchmark"
require "fileutils"
require "timeout"
require "memory_profiler"
require "addressable/template"

# Compares Addressable::Template's two engines, :regexp and :machine, for
# rake profile:template_machine. See TEMPLATE_MACHINE_PLAN.md.
#
# Each row times one operation with both engines and checks that they give
# the same output, so a fast wrong answer isn't mistaken for a speedup.
module TemplateMachineProfile
  ENGINES = [:regexp, :machine].freeze

  CASES = [
    {
      name: "simple",
      pattern: "http://example.com/users/{id}",
      values: { "id" => "42" }
    },
    {
      name: "path, query, prefix",
      pattern: "https://google.com{/path}{?foo,bar:12}#cat",
      values: {
        "path" => "a",
        "foo" => "longstring",
        "bar" => "longeststringavailable"
      }
    },
    {
      name: "exploded",
      pattern: "http://example.com{/segments*}{?query*}",
      values: {
        "segments" => ["a", "b", "c"],
        "query" => { "x" => "1", "y" => "2" }
      }
    },
    {
      name: "reserved, fragment",
      pattern: "{+base}/search{?q,lang}{#section}",
      values: {
        "base" => "http://example.com/api",
        "q" => "café au lait",
        "lang" => "fr",
        "section" => "results"
      }
    },
    # Longer URIs, where the matcher's cost per character shows.
    {
      name: "API path and query",
      pattern: "/repos/{owner}/{repo}/issues{/number}" \
        "{?state,labels,page,per_page}",
      values: {
        "owner" => "example", "repo" => "project", "number" => "512",
        "state" => "open", "labels" => "bug", "page" => "2",
        "per_page" => "100"
      }
    },
    {
      name: "long query",
      pattern: "/q{?a,b,c}",
      values: { "a" => "x" * 300, "b" => "y" * 300, "c" => "z" * 300 }
    },
    {
      name: "long path",
      pattern: "/files{/path*}",
      values: { "path" => Array.new(60) { "segment" } }
    }
  ].map do |c|
    first = c[:values].keys.first
    c.merge(
      # partial_expand gets only the first variable.
      partial: { first => c[:values][first] },
      # match and extract get the URI that Template expands the values to.
      uri: Addressable::Template.new(c[:pattern], engine: :regexp)
        .expand(c[:values]).to_s
    ).freeze
  end.freeze

  OPERATIONS = {
    "expand" => lambda { |t, c| t.expand(c[:values]) },
    "partial_expand" => lambda { |t, c| t.partial_expand(c[:partial]) },
    "match" => lambda { |t, c| t.match(c[:uri]) },
    "extract" => lambda { |t, c| t.extract(c[:uri]) }
  }.freeze

  # Patterns and payloads modelled on the "with adversarial input" specs in
  # spec/addressable/template_match_spec.rb. None of the payloads match.
  # The report shows how each payload ends.
  ADVERSARIAL = [
    ["{/foo*}", lambda { |n| "/" + ("a/" * n) + "!" }],
    ["{?foo*,bar*}", lambda { |n| "?" + ("a=1&" * n) + " " }],
    ["{;foo*,bar*,baz*}", lambda { |n| ";" + ("a=1;" * n) + "!" }],
    ["{a}{b}{c}", lambda { |n| ("a" * n) + "!" }],
    ["{+v1,v2,v3,v4,v5,v6,v7,v8,v9,v10}", lambda { |n| ("a," * n) + " " }],
    # The shapes in template_machine_spec.rb's linear-time checks with
    # the most states to try at each position, first without the literal
    # the template ends with, then ending with it, so that a check that
    # the URI holds the template's literals can't reject it before the
    # search.
    ["{a}" * 12 + "!", lambda { |n| "a" * n }],
    ["{a}" * 12 + "!", lambda { |n| ("a" * n) + "?!" }],
    ["{/a*,b*,c*}!", lambda { |n| "/" * n }],
    ["{/a*,b*,c*}!", lambda { |n| ("/" * n) + "?!" }],
    ["{;a*}{;b*}{;c}!", lambda { |n| ";a=1" * n }],
    ["{;a*}{;b*}{;c}!", lambda { |n| (";a=1" * n) + "?!" }],
    # a's value is followed by "=", which b's name needs next, so it
    # can't skip to the end of its run.
    ["{?a,b,c}!", lambda { |n| "?a=" + ("x" * n) + "=?!" }]
  ].freeze
  ADVERSARIAL_SIZES = [500, 2000].freeze
  ADVERSARIAL_TIMEOUT = 10

  # Patterns modelled on "checks long templates in linear time" in
  # spec/addressable/template_spec.rb. Each is invalid, so the first expand
  # parses it and raises.
  ADVERSARIAL_PARSE = {
    "{ * n" => lambda { |n| "{" * n },
    "{a * n" => lambda { |n| "{a" * n },
    "{a.a.…!}" => lambda { |n| "{" + ("a." * n) + "!}" },
    "{a,a,…!}" => lambda { |n| "{" + ("a," * n) + "!}" },
    "{%2%2…}" => lambda { |n| "{" + ("%2" * n) + "}" },
    "é{a} * n + }" => lambda { |n| ("é{a}" * n) + "}" }
  }.freeze
  ADVERSARIAL_PARSE_SIZES = [10_000, 40_000].freeze

  REPORT_DIR = "tmp/template_machine"

  module_function

  def run(iterations:)
    FileUtils.mkdir_p(REPORT_DIR)
    puts "#{RUBY_DESCRIPTION}, #{iterations} calls per timing"
    puts
    compare_operations(iterations)
    puts
    compare_adversarial
    puts
    compare_adversarial_parse
    puts
    puts "MemoryProfiler reports: #{REPORT_DIR}/"
  end

  def compare_operations(iterations)
    puts format(
      "%-20s %-15s %-7s %-9s %12s %12s %7s %12s %12s %10s %10s",
      "case", "operation", "template", "output",
      "regexp", "machine", "ratio", "regexp", "machine", "regexp", "machine"
    )
    puts format(
      "%-55s %25s %7s %25s %21s",
      "", "µs per call", "", "objects per call", "KB per call"
    )
    CASES.each do |c|
      OPERATIONS.each do |op_name, op|
        ["new", "reused"].each do |mode|
          compare_operation(c, op_name, op, mode, iterations)
        end
      end
    end
    puts
    puts "output: same = both give the same result, or raise the same " \
      "error; differs = :machine's result is wrong, so its numbers don't " \
      "count. An engine that raises isn't timed."
  end

  def compare_operation(c, op_name, op, mode, iterations)
    calls = ENGINES.map do |engine|
      reused = Addressable::Template.new(c[:pattern], engine: engine)
      call =
        if mode == "new"
          lambda do
            op.call(Addressable::Template.new(c[:pattern], engine: engine), c)
          end
        else
          lambda { op.call(reused, c) }
        end
      [engine, call]
    end
    outputs = calls.map { |_, call| attempt(&call) }
    status = status(*outputs)

    times = []
    objects = []
    kilobytes = []
    calls.each_with_index do |(engine, call), i|
      if outputs[i][1]
        times << nil
        objects << nil
        kilobytes << nil
        next
      end
      times << time_per_call(call, iterations)
      count, bytes = allocations_per_call(
        call, [iterations / 20, 100].max,
        "#{c[:name]}-#{op_name}-#{mode}-#{engine}"
      )
      objects << count
      kilobytes << bytes / 1000
    end

    puts format(
      "%-20s %-15s %-7s %-9s %12s %12s %7s %12s %12s %10s %10s",
      c[:name], op_name, mode, status,
      number(times[0]), number(times[1]), ratio(times[1], times[0]),
      number(objects[0]), number(objects[1]),
      number(kilobytes[0]), number(kilobytes[1])
    )
  end

  # The result of a call, made comparable across the engines, and the
  # exception it raised, if any.
  def attempt
    [comparable(yield), nil]
  rescue StandardError => e
    [nil, e]
  end

  # A URI from expand as a string, a MatchData as its mapping, a Template
  # from partial_expand as its pattern, and anything else (extract's Hash,
  # or nil) as it is.
  def comparable(result)
    if result.is_a?(Addressable::URI)
      result.to_s
    elsif result.respond_to?(:mapping)
      result.mapping
    elsif result.respond_to?(:pattern)
      result.pattern
    else
      result
    end
  end

  def status(template, machine)
    template_result, template_error = template
    machine_result, machine_error = machine
    same =
      if machine_error || template_error
        # Both should raise the same error.
        error_name(machine_error) == error_name(template_error)
      else
        machine_result == template_result
      end
    same ? "same" : "differs"
  end

  def error_name(error)
    error && error.class.name.split("::").last
  end

  def time_per_call(call, iterations)
    call.call
    seconds = Benchmark.realtime { iterations.times { call.call } }
    seconds * 1_000_000 / iterations
  end

  # The objects and bytes one call allocates, on average.
  def allocations_per_call(call, iterations, name)
    report = MemoryProfiler.report { iterations.times { call.call } }
    report.pretty_print(
      to_file: File.join(REPORT_DIR, name.tr(" ,", "_") + ".txt"),
      scale_bytes: true, normalize_paths: true
    )
    [
      report.total_allocated.to_f / iterations,
      report.total_allocated_memsize.to_f / iterations
    ]
  end

  def compare_adversarial
    sizes = ADVERSARIAL_SIZES
    puts "Adversarial match (no payload matches). Time for one call, in ms; " \
      "x#{sizes.last / sizes.first} input should take about " \
      "x#{sizes.last / sizes.first} time if it's linear. MB: what one call " \
      "allocates at n=#{sizes.last}."
    puts format(
      "%-36s %-6s %-12s %10s %10s %7s %8s",
      "pattern", "ends", "", *sizes.map { |n| "n=#{n}" }, "growth", "MB"
    )
    ADVERSARIAL.each do |pattern, payload|
      ending = payload.call(2)[-2, 2].inspect
      ENGINES.each do |engine|
        times = sizes.map do |n|
          adversarial_time(engine, pattern, payload.call(n))
        end
        growth =
          if times.all? { |t| t.is_a?(Float) }
            ratio(times.last, times.first)
          else
            ""
          end
        # Only measured if the call finished in time.
        megabytes =
          if times.last.is_a?(Float)
            adversarial_megabytes(engine, pattern, payload.call(sizes.last))
          end
        puts format(
          "%-36s %-6s %-12s %10s %10s %7s %8s",
          pattern, ending, engine,
          *times.map { |t| t.is_a?(Float) ? number(t) : t }, growth,
          number(megabytes)
        )
      end
    end
  end

  # What one match allocates, in MB, on a template that has matched once
  # already, so building it isn't counted.
  def adversarial_megabytes(engine, pattern, payload)
    template = Addressable::Template.new(pattern, engine: engine)
    template.match(payload)
    report = MemoryProfiler.report { template.match(payload) }
    report.total_allocated_memsize / 1_000_000.0
  end

  # The fastest of three calls, in ms, or why there's no time.
  def adversarial_time(engine, pattern, payload)
    template = Addressable::Template.new(pattern, engine: engine)
    best = nil
    3.times do
      result = nil
      seconds = Benchmark.realtime do
        Timeout.timeout(ADVERSARIAL_TIMEOUT) { result = template.match(payload) }
      end
      return "matched" unless result.nil?
      best = seconds if best.nil? || seconds < best
    end
    best * 1000
  rescue Timeout::Error
    ">#{ADVERSARIAL_TIMEOUT}s"
  rescue StandardError => e
    e.class.name.split("::").last
  end

  def compare_adversarial_parse
    sizes = ADVERSARIAL_PARSE_SIZES
    puts "Adversarial parse (every pattern is invalid). Time for the first " \
      "expand of a new template, in ms; x#{sizes.last / sizes.first} input " \
      "should take about x#{sizes.last / sizes.first} time if it's linear."
    puts format(
      "%-36s %-12s %10s %10s %7s",
      "pattern", "", *sizes.map { |n| "n=#{n}" }, "growth"
    )
    ADVERSARIAL_PARSE.each do |name, pattern|
      ENGINES.each do |engine|
        times = sizes.map { |n| parse_time(engine, pattern.call(n)) }
        growth =
          if times.all? { |t| t.is_a?(Float) }
            ratio(times.last, times.first)
          else
            ""
          end
        puts format(
          "%-36s %-12s %10s %10s %7s",
          name, engine, *times.map { |t| t.is_a?(Float) ? number(t) : t },
          growth
        )
      end
    end
  end

  # The fastest of three first expands, in ms, or why there's no time.
  def parse_time(engine, pattern)
    best = nil
    3.times do
      template = Addressable::Template.new(pattern, engine: engine)
      seconds = Benchmark.realtime do
        Timeout.timeout(ADVERSARIAL_TIMEOUT) do
          begin
            template.expand({})
            return "valid"
          rescue Addressable::Template::InvalidTemplateError
            # Expected: the pattern is invalid.
          end
        end
      end
      best = seconds if best.nil? || seconds < best
    end
    best * 1000
  rescue Timeout::Error
    ">#{ADVERSARIAL_TIMEOUT}s"
  rescue StandardError => e
    e.class.name.split("::").last
  end

  def number(value)
    return "-" if value.nil?
    value >= 100 ? value.round.to_s : format("%.2f", value)
  end

  def ratio(value, base)
    return "-" if value.nil? || base.nil? || base.zero?
    format("%.2fx", value / base)
  end
end
