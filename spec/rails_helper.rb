require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
# Load factory_bot_rails before the app boots so its railtie picks up the factory path
# the dummy app adds (config.factory_bot.definition_file_paths).
require 'factory_bot_rails'
require_relative '../spec/dummy/config/environment'
require_relative 'rails_setup'
require 'capybara/rspec'

RSpec.configure do |config|
  config.fixture_paths = [
    Rails.root.join('spec/fixtures')
  ]

  # Engine Routing Helper
  # This is vital. Without it, controller specs won't know how to generate URLs
  # for the engine's isolated routes.
  config.include TudlaAccounting::Engine.routes.url_helpers
end
