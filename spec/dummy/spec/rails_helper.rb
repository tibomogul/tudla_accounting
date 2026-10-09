# The demo app's own specs: run from spec/dummy (cd spec/dummy && bundle exec rspec).
# They boot the dummy app with the demo loaded; the engine's specs (spec/ at the
# engine root) boot it without.
ENV["TUDLA_DEMO"] = "1"
ENV["RAILS_ENV"] ||= "test"
require "factory_bot_rails"
require_relative "../config/environment"
require_relative "../../rails_setup"

Rails.root.glob("spec/support/**/*.rb").sort.each { |file| require file }

RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers

  # As in the engine's spec_helper, which isn't loaded here: it starts SimpleCov for the engine.
  config.expect_with(:rspec) { |expectations| expectations.include_chain_clauses_in_custom_matcher_descriptions = true }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.shared_context_metadata_behavior = :apply_to_host_groups
end
