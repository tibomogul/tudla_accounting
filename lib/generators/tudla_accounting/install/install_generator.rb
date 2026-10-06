# frozen_string_literal: true

require "rails/generators"

module TudlaAccounting
  module Generators
    # rails generate tudla_accounting:install [--mount-path=/accounting] [--skip-migrations]
    #
    # Sets a host app up for the engine: an initializer with every setting, the engine
    # mounted in the routes, its migrations copied in, and its styles imported into the
    # app's Tailwind build.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      class_option :mount_path, type: :string, default: "/accounting", desc: "Where to mount the engine's pages"
      class_option :skip_migrations, type: :boolean, default: false, desc: "Don't copy the engine's migrations"

      TAILWIND_CSS = "app/assets/tailwind/application.css"
      TAILWIND_IMPORT = %(@import "../builds/tailwind/tudla_accounting";)

      def create_initializer
        template "tudla_accounting.rb.tt", "config/initializers/tudla_accounting.rb"
      end

      def mount_engine
        route %(mount TudlaAccounting::Engine => "#{options[:mount_path]}")
      end

      # tailwindcss-rails builds the engine's stylesheet into app/assets/builds/tailwind;
      # importing it compiles the engine's pages' classes into the app's tailwind.css.
      def import_styles
        path = File.join(destination_root, TAILWIND_CSS)
        unless File.exist?(path)
          say_status :skip, "#{TAILWIND_CSS} not found; add #{TAILWIND_IMPORT} to your Tailwind entry point", :yellow
          return
        end
        return if File.read(path).include?(TAILWIND_IMPORT)

        append_to_file TAILWIND_CSS, "\n/* TudlaAccounting's pages */\n#{TAILWIND_IMPORT}\n"
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
        TEXT
      end
    end
  end
end
