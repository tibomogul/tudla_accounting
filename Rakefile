require "bundler/setup"

APP_RAKEFILE = File.expand_path("spec/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

require "bundler/gem_tasks"

# The engine's pages' stylesheet, built from app/assets/tailwind/tudla_accounting/engine.css
# into app/assets/builds/tudla_accounting.css, which ships in the gem so host apps need no
# Tailwind. Build it after changing the views' classes (bin/dev watches it);
# spec/integration/built_stylesheet_spec.rb fails while it's out of date.
namespace :tudla_accounting do
  namespace :css do
    def tailwind(*args)
      require "tailwindcss/ruby"
      sh Tailwindcss::Ruby.executable, "-i", "app/assets/tailwind/tudla_accounting/engine.css", "-o", "app/assets/builds/tudla_accounting.css", "--minify", *args
    end

    desc "Build the engine's stylesheet"
    task(:build) { tailwind }

    desc "Rebuild the engine's stylesheet as its sources change"
    task(:watch) { tailwind("--watch=always") }
  end

  # The pages' JavaScript, built into app/assets/builds/tudla_accounting.js (see
  # tasks/javascript_bundle.rb); spec/integration/built_javascript_spec.rb fails while
  # it's out of date.
  namespace :js do
    desc "Build the engine's JavaScript"
    task :build do
      require_relative "tasks/javascript_bundle"
      JavascriptBundle.new(__dir__).write
      puts "Built #{JavascriptBundle::OUTPUT}"
    end

    desc "Rebuild the engine's JavaScript as its sources change"
    task :watch do
      require_relative "tasks/javascript_bundle"
      $stdout.sync = true
      bundle = JavascriptBundle.new(__dir__)
      built = nil
      loop do
        stamp = bundle.sources.map { |file| [ file.to_s, File.mtime(file) ] }
        if stamp != built
          begin
            bundle.write
            puts "Built #{JavascriptBundle::OUTPUT}"
          rescue JavascriptBundle::Error, SyntaxError => e
            warn e.message
          end
          built = stamp
        end
        sleep 1
      end
    end
  end
end
