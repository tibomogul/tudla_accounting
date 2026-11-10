source "https://rubygems.org"

# Specify your gem's dependencies in tudla_accounting.gemspec.
gemspec

gem "puma"

# The dummy app (spec/dummy) runs on the Solid trifecta; host apps choose their own.
gem "solid_queue"
gem "solid_cache"
gem "solid_cable"

gem "propshaft"
# The dummy app's own pages (DaisyUI, importmap, Stimulus); the engine's ship built
# (rake tudla_accounting:css:build and tudla_accounting:js:build, which takes Stimulus from
# stimulus-rails).
gem "tailwindcss-rails", "~> 4.0"
gem "importmap-rails", "~> 2.0"
gem "stimulus-rails", "~> 1.3"

group :development, :test do
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "simplecov", require: false
  gem "capybara"
  gem "selenium-webdriver"
  gem "debug", ">= 1.0.0"
  gem "spreadsheet" # for the optional RbaForexRateProvider (host apps add it to use it)
  gem "caxlsx", "~> 4.1" # for the optional Excel downloads of reports (host apps add it to use them)
  gem "ferrum", "~> 0.17" # for the optional PDFs, through headless Chrome (host apps add it to use them)
  gem "pdf-reader", "~> 2.14" # to read the text of the PDFs in specs
end

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
