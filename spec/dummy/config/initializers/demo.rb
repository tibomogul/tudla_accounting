# Configuration only the demo needs. The engine's specs boot without the demo
# (see config.x.demo in config/application.rb), so nothing here reaches them.
return unless Rails.configuration.x.demo

# The stand-in login shows the demo's button instead of listing Demo Co with the rest.
Rails.configuration.x.sign_in_partial = "demo/sessions/button"
Rails.configuration.x.sign_in_organizations = ->(organizations) { organizations.where.not(name: Demo::Seeder::NAME) }

# The demo's invoices are the engine's own; its payments are the receipts' sources, applied
# to those invoices, so the books track what each customer owes (the aging report and
# statements).
TudlaAccounting.configure do |config|
  config.carrying_amount_sources = { "Demo::Payment" => :receipt }
  config.related_party_method = :customer
  config.document_header = ->(organization) { "#{organization.name}\n1 Demo Street, Sydney NSW 2000\nABN 12 345 678 901" }
end
