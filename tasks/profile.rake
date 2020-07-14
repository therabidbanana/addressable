# frozen_string_literal: true

namespace :profile do
  desc "Profile Template match memory allocations"
  task :template_match_memory do
    require "memory_profiler"
    require "addressable/template"

    start_at = Time.now.to_f
    template = Addressable::Template.new("http://example.com/{?one,two,three}")
    report = MemoryProfiler.report do
      30_000.times do
        template.match(
          "http://example.com/?one=one&two=floo&three=me"
        )
      end
    end
    end_at = Time.now.to_f
    print_options = { scale_bytes: true, normalize_paths: true }
    puts "\n\n"

    if ENV["CI"]
      report.pretty_print(print_options)
    else
      t_allocated = report.scale_bytes(report.total_allocated_memsize)
      t_retained  = report.scale_bytes(report.total_retained_memsize)

      puts "Total allocated: #{t_allocated} (#{report.total_allocated} objects)"
      puts "Total retained:  #{t_retained} (#{report.total_retained} objects)"
      puts "Took #{end_at - start_at} seconds"
      FileUtils.mkdir_p("tmp")
      report.pretty_print(to_file: "tmp/memprof.txt", **print_options)
    end
  end

  desc "TemplateMachine"
  task :template_machine do
    require "memory_profiler"
    require "benchmark"
    require "addressable/template"
    require "addressable/uri_template"

    template = "https://google.com{/path}{?foo,bar:12}#cat"
    values = {
      "path" => "a",
      "foo" => "longstring",
      "bar" => "longeststringavailable"
    }
    control = Addressable::Template
    experiment = Addressable::UriTemplate
    controlled = control.new(template)
    experimented = experiment.new(template)

    control_fresh_report = MemoryProfiler.report do
      10_000.times do
        control.new(template).expand(values)
      end
    end
    experiment_fresh_report = MemoryProfiler.report do
      10_000.times do
        experiment.new(template).expand(values)
      end
    end
    control_singleton_report = MemoryProfiler.report do
      10_000.times do
        controlled.expand(values)
      end
    end
    experiment_singleton_report = MemoryProfiler.report do
      10_000.times do
        experimented.expand(values)
      end
    end
    print_options = { scale_bytes: true, normalize_paths: true }
    puts "\n\n"

    Benchmark.bmbm do |x|
      x.report("Control - fresh template"){
        20_000.times do
          control.new(template).expand(values)
        end
      }
      x.report("Experiment - fresh template"){
        20_000.times do
          experiment.new(template).expand(values)
        end
      }
      x.report("Control - single template"){
        20_000.times do
          controlled.expand(values)
        end
      }
      x.report("Experimented - single template"){
        20_000.times do
          experimented.expand(values)
        end
      }
    end

    if ENV["CI"]
      report.pretty_print(print_options)
    else
      puts "\n\n"
      c_allocated = control_fresh_report.scale_bytes(control_fresh_report.total_allocated_memsize)
      c_retained  = control_fresh_report.scale_bytes(control_fresh_report.total_retained_memsize)
      e_allocated = control_fresh_report.scale_bytes(experiment_fresh_report.total_allocated_memsize)
      e_retained  = control_fresh_report.scale_bytes(experiment_fresh_report.total_retained_memsize)

      puts "Control:\n"
      puts "Total allocated: #{c_allocated} (#{control_fresh_report.total_allocated} objects)"
      puts "Total retained:  #{c_retained} (#{control_fresh_report.total_retained} objects)"
      puts "\n\n"
      puts "Experiment:\n"
      puts "Total allocated: #{e_allocated} (#{experiment_fresh_report.total_allocated} objects)"
      puts "Total retained:  #{e_retained} (#{experiment_fresh_report.total_retained} objects)"

      puts "\n\n"

      FileUtils.mkdir_p("profiling")
      control_fresh_report.pretty_print(to_file: "profiling/control_fresh.txt", **print_options)
      experiment_fresh_report.pretty_print(to_file: "profiling/experiment_fresh.txt", **print_options)
      control_singleton_report.pretty_print(to_file: "profiling/control_singleton.txt", **print_options)
      experiment_singleton_report.pretty_print(to_file: "profiling/experiment_singleton.txt", **print_options)
    end
  end

  desc "TemplateMachine Match"
  task :template_machine_match do
    require "memory_profiler"
    require "addressable/template"
    require "addressable/uri_template"

    start_at = Time.now.to_f
    report = MemoryProfiler.report do
      template = Addressable::UriTemplate.new(
        "https://google.com{/path}{?foo,bar:12}#cat"
      )
      10_000.times do
        results = template.match("https://google.com/a?foo=longstring,longeststrin#cat")
      end
    end
    end_at = Time.now.to_f
    print_options = { scale_bytes: true, normalize_paths: true }
    puts "\n\n"

    if ENV["CI"]
      report.pretty_print(print_options)
    else
      t_allocated = report.scale_bytes(report.total_allocated_memsize)
      t_retained  = report.scale_bytes(report.total_retained_memsize)

      puts "Total allocated: #{t_allocated} (#{report.total_allocated} objects)"
      puts "Total retained:  #{t_retained} (#{report.total_retained} objects)"
      puts "Total time #{end_at - start_at} seconds"

      FileUtils.mkdir_p("tmp")
      report.pretty_print(to_file: "tmp/memprof.txt", **print_options)
    end
  end
  desc "Profile memory allocations"
  task :memory do
    require "memory_profiler"
    require "addressable/uri"
    if ENV["IDNA_MODE"] == "pure"
      Addressable.send(:remove_const, :IDNA)
      load "addressable/idna/pure.rb"
    end

    start_at = Time.now.to_f
    report = MemoryProfiler.report do
      30_000.times do
        Addressable::URI.parse(
          "http://google.com/stuff/../?with_lots=of&params=asdff#!stuff"
        ).normalize
      end
    end
    end_at = Time.now.to_f
    print_options = { scale_bytes: true, normalize_paths: true }
    puts "\n\n"

    if ENV["CI"]
      report.pretty_print(**print_options)
    else
      t_allocated = report.scale_bytes(report.total_allocated_memsize)
      t_retained  = report.scale_bytes(report.total_retained_memsize)

      puts "Total allocated: #{t_allocated} (#{report.total_allocated} objects)"
      puts "Total retained:  #{t_retained} (#{report.total_retained} objects)"
      puts "Took #{end_at - start_at} seconds"

      FileUtils.mkdir_p("tmp")
      report.pretty_print(to_file: "tmp/memprof.txt", **print_options)
    end
  end
end
