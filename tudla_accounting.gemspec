require_relative "lib/tudla_accounting/version"

Gem::Specification.new do |spec|
  spec.name        = "tudla_accounting"
  spec.version     = TudlaAccounting::VERSION
  spec.authors     = [ "Tibo Mogul" ]
  spec.email       = [ "tibo.mogul@gmail.com" ]
  spec.homepage    = "https://github.com/tibomogul/tudla_accounting"
  spec.summary     = "Double-entry accounting for Rails apps, as a mountable engine."
  spec.description = "A Rails engine that keeps double-entry books for your app's organizations: chart of accounts, " \
                     "periods with year-end close, journal entries, receivables and payables with payment allocation, " \
                     "multi-currency with realized and unrealized exchange differences, tax, bank reconciliation, " \
                     "reporting dimensions, financial reports and an audit trail, with web pages to run them. Requires PostgreSQL."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.add_dependency "rails", "~> 8.1", ">= 8.1.1"
  spec.add_dependency "pg", "~> 1.5"                 # the ledger relies on PostgreSQL (jsonb, triggers)
  spec.add_dependency "tailwindcss-rails", "~> 4.0"  # the host's build compiles the engine's styles
  spec.add_dependency "importmap-rails", "~> 2.0"
  spec.add_dependency "stimulus-rails", "~> 1.3"
  spec.add_dependency "money-rails", ">= 1.15", "< 4"
  spec.add_dependency "ancestry", "~> 5.0"
  spec.add_dependency "csv", "~> 3.3"               # no longer a default gem from Ruby 3.4
  spec.add_dependency "roo", ">= 2.10", "< 4"        # XLSX chart of accounts import
end
