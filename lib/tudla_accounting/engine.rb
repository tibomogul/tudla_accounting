module TudlaAccounting
  class Engine < ::Rails::Engine
    isolate_namespace TudlaAccounting

    # After the host app's initializers, so TudlaAccounting.configure calls made
    # there are reflected in money-rails' defaults.
    config.after_initialize do
      TudlaAccounting.apply_money_settings!
    end

    config.generators do |g|
      g.test_framework :rspec
      g.fixture_replacement :factory_bot
      g.factory_bot dir: "spec/factories"
    end

    # Advanced FactoryBot Configuration
    # We hook into the initializer to append the path relative to the Engine's root.
    initializer "tudla_accounting.factories", after: "factory_bot.set_factory_paths" do
      if defined?(FactoryBot)
        FactoryBot.definition_file_paths << File.expand_path("../../../spec/factories", __FILE__)
      end
    end

    # Triggers aren't in schema.rb, so they go back in after every schema load.
    initializer "tudla_accounting.schema_loading" do
      ActiveSupport.on_load(:active_record) do
        require "active_record/tasks/database_tasks"
        ActiveRecord::Tasks::DatabaseTasks.singleton_class.prepend(TudlaAccounting::DatabaseProtection::SchemaLoading)
      end
    end

    initializer "tudla_accounting.importmap", before: "importmap" do |app|
      if app.config.respond_to?(:importmap)
        app.config.importmap.paths << Engine.root.join("config/importmap.rb")
        app.config.importmap.cache_sweepers << Engine.root.join("app/javascript")
      end
    end

    initializer "tudla_accounting.assets" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << Engine.root.join("app/javascript")
      end
    end

    # Ensure the engine's assets are visible to the host's pipeline
    initializer "tudla_accounting.assets.precompile" do |app|
      app.config.assets.paths << root.join("app/assets/tailwind")
    end
  end
end
