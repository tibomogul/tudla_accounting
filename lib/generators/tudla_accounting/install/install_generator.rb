# frozen_string_literal: true

require "rails/generators"

module TudlaAccounting
  module Generators
    # rails generate tudla_accounting:install [--mount-path=/accounting] [--skip-migrations]
    #
    # Sets a host app up for the engine: an initializer with every setting, the engine
    # mounted in the routes, and its migrations copied in. The pages bring their own built
    # stylesheet, so the app's own CSS is left alone.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      class_option :mount_path, type: :string, default: "/accounting", desc: "Where to mount the engine's pages"
      class_option :skip_migrations, type: :boolean, default: false, desc: "Don't copy the engine's migrations"

      def create_initializer
        template "tudla_accounting.rb.tt", "config/initializers/tudla_accounting.rb"
      end

      def mount_engine
        route %(mount TudlaAccounting::Engine => "#{options[:mount_path]}")
      end

      def copy_migrations
        rake "tudla_accounting:install:migrations" unless options[:skip_migrations]
      end

      def show_next_steps
        say <<~TEXT

          TudlaAccounting is installed. Next:
            1. Fill in config/initializers/tudla_accounting.rb (at least current_organization).
            2. bin/rails db:migrate
            3. Open #{options[:mount_path]} once signed in, create a financial year and load a chart of accounts.

          To attach receipts to entries, the app needs Active Storage (bin/rails active_storage:install
          if it isn't set up); the pages leave attachments out until it is.
        TEXT
      end
    end
  end
end
