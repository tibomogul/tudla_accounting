module TudlaAccounting
  class Engine < ::Rails::Engine
    isolate_namespace TudlaAccounting

    config.generators do |g|
      g.test_framework :rspec
      g.fixture_replacement :factory_bot
      g.factory_bot dir: "spec/factories"
    end

    # Triggers aren't in schema.rb, so they go back in after every schema load.
    # Reports download as .xlsx when the host bundles caxlsx (TudlaAccounting.xlsx?).
    initializer "tudla_accounting.mime_types" do
      Mime::Type.register "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", :xlsx unless Mime::Type.lookup_by_extension(:xlsx)
    end

    initializer "tudla_accounting.schema_loading" do
      ActiveSupport.on_load(:active_record) do
        require "active_record/tasks/database_tasks"
        ActiveRecord::Tasks::DatabaseTasks.singleton_class.prepend(TudlaAccounting::DatabaseProtection::SchemaLoading)
      end
    end

    # The pages' built stylesheet and JavaScript (tudla_accounting.css and .js), for
    # Propshaft, which serves everything on its paths, and Sprockets, which needs them
    # named for precompiling.
    initializer "tudla_accounting.assets.precompile" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app/assets/builds")
        app.config.assets.precompile += %w[tudla_accounting.css tudla_accounting.js] if defined?(Sprockets)
      end
    end
  end
end
