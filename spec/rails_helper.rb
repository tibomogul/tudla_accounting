require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
# Load factory_bot_rails before the app boots so its railtie and the engine's
# "tudla_accounting.factories" initializer register the engine's factory path.
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
