# Setup shared by the engine's specs (spec/rails_helper.rb) and the demo's
# (spec/dummy/spec/rails_helper.rb). Require it after booting the dummy app.

# The container sets RAILS_ENV=development, which would point the specs at the dev database.
abort("Run the specs with RAILS_ENV=test (got #{Rails.env})") unless Rails.env.test?

require "rspec/rails"

# Loading schema.rb into the test database records which migrations it covers from the
# dummy app's db/migrate only; include the engine's, or after a reload the engine's
# migrations look pending.
ActiveRecord::Tasks::DatabaseTasks.migrations_paths |= [ TudlaAccounting::Engine.root.join("db/migrate").to_s ]

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  # schema.rb can't hold the triggers protecting posted entries; make sure the test
  # database has them even when it was built from the schema.
  config.before(:suite) do
    TudlaAccounting::DatabaseProtection.install! unless TudlaAccounting::DatabaseProtection.installed?
  end

  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
  config.include FactoryBot::Syntax::Methods
end
