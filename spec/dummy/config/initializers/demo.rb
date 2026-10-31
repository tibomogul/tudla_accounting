# Configuration only the demo needs. The engine's specs boot without the demo
# (see config.x.demo in config/application.rb), so nothing here reaches them.
return unless Rails.configuration.x.demo

# The stand-in login shows the demo's buttons instead of listing its books with the rest.
Rails.configuration.x.sign_in_partial = "demo/sessions/button"
Rails.configuration.x.sign_in_organizations = ->(organizations) { organizations.where.not(name: [ Demo::Seeder::NAME, Demo::EuroSeeder::NAME, Demo::PesoSeeder::NAME ]) }

# Who the demo's invoices are from, when printed and emailed (to files in tmp/mails).
TudlaAccounting.configure do |config|
  config.document_mail_from = "Demo Co <accounts@demo-co.example>"
  # Overdue customers are reminded a week, a fortnight and a month after the due date
  # (by SendRemindersJob, in config/recurring.yml, or from Sales > Reminders due).
  config.reminder_days = [ 7, 14, 30 ]
  config.document_header = lambda do |organization|
    case organization.name
    when Demo::EuroSeeder::NAME then "#{organization.name}\nDemostraße 1, 10115 Berlin\nUSt-IdNr. DE123456789"
    when Demo::PesoSeeder::NAME then "#{organization.name}\n1 Ayala Avenue, Makati City 1226\nTIN 000-123-456-000"
    else "#{organization.name}\n1 Demo Street, Sydney NSW 2000\nABN 12 345 678 901"
    end
  end
end

# Made-up USD/EUR/PHP rates for any date, for the foreign invoices and payments in the books
# (set on each reload, as the provider is reloadable demo code).
Rails.application.config.to_prepare do
  TudlaAccounting.configuration.forex_rate_provider = Demo::ForexRateProvider.new
end
