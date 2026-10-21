# Configuration only the demo needs. The engine's specs boot without the demo
# (see config.x.demo in config/application.rb), so nothing here reaches them.
return unless Rails.configuration.x.demo

# The stand-in login shows the demo's button instead of listing Demo Co with the rest.
Rails.configuration.x.sign_in_partial = "demo/sessions/button"
Rails.configuration.x.sign_in_organizations = ->(organizations) { organizations.where.not(name: Demo::Seeder::NAME) }

# The demo's invoices and payments are the entries' sources, so the books track what
# each customer owes (the aging report and statements).
TudlaAccounting.configure do |config|
  config.carrying_amount_sources = { "Demo::Invoice" => :receivable, "Demo::Payment" => :receipt }
  config.related_party_method = :customer
end
