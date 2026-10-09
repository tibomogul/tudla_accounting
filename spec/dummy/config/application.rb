require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f

    # For compatibility with applications that use this config
    config.action_controller.include_all_helpers = false

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # Hooks into the stand-in login (SessionsController#new), set by the demo's initializer:
    # a partial rendered below the organizations, and a filter on the organizations listed.
    config.x.sign_in_partial = nil
    config.x.sign_in_organizations = ->(organizations) { organizations }

    # The demo (the Demo:: namespace in app/*/demo, its initializer, routes and seeds)
    # runs in development and in the demo's own specs (spec/dummy/spec, which set
    # TUDLA_DEMO=1). The engine's specs boot without it, so they see only the harness.
    config.x.demo = ENV.fetch("TUDLA_DEMO") { Rails.env.test? ? "0" : "1" } == "1"
    unless config.x.demo
      Rails.autoloaders.main.ignore(*Dir[File.expand_path("../app/*/demo", __dir__)])
    end
  end
end
