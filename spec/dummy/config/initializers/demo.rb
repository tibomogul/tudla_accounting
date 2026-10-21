# Configuration only the demo needs. The engine's specs boot without the demo
# (see config.x.demo in config/application.rb), so nothing here reaches them.
return unless Rails.configuration.x.demo

# The stand-in login shows the demo's button instead of listing Demo Co with the rest.
Rails.configuration.x.sign_in_partial = "demo/sessions/button"
Rails.configuration.x.sign_in_organizations = ->(organizations) { organizations.where.not(name: Demo::Seeder::NAME) }

# Who the demo's invoices are from, when printed and emailed (to files in tmp/mails).
TudlaAccounting.configure do |config|
  config.document_mail_from = "Demo Co <accounts@demo-co.example>"
  config.document_header = ->(organization) { "#{organization.name}\n1 Demo Street, Sydney NSW 2000\nABN 12 345 678 901" }
end
