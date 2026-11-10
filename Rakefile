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
end
