require_relative "lib/tudla_accounting/version"

Gem::Specification.new do |spec|
  spec.name        = "tudla_accounting"
  spec.version     = TudlaAccounting::VERSION
  spec.authors     = [ "Tibo Mogul" ]
  spec.email       = [ "tibo.mogul@gmail.com" ]
  spec.homepage    = "https://tibomogul.github.io/"
  spec.summary     = "A Solid-integrated Rails 8 Engine."
  spec.description = "Provides core domain logic with RSpec, Solid Queue, and Tailwind integration."
  spec.license     = "MIT"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the "allowed_push_host"
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"

  # spec.metadata["homepage_uri"] = spec.homepage
  # spec.metadata["source_code_uri"] = "TODO: Put your gem's public repo URL here."
  # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.1.1"
  spec.add_dependency "solid_queue"
  spec.add_dependency "solid_cache"
  spec.add_dependency "solid_cable"
  spec.add_dependency "tailwindcss-rails"
  spec.add_dependency "importmap-rails"
  spec.add_dependency "money-rails"
  spec.add_dependency "ancestry"

  # Development Dependencies
  # These are used only for running the engine's test suite.
  spec.add_development_dependency "sqlite3"
  spec.add_development_dependency "pg" # Optional, if testing Postgres compat
  spec.add_development_dependency "rspec-rails"
  spec.add_development_dependency "factory_bot_rails"
  spec.add_development_dependency "simplecov"
  spec.add_development_dependency "capybara"
  spec.add_development_dependency "selenium-webdriver"
  spec.add_development_dependency "stimulus-rails"
  spec.add_development_dependency "debug"
end
