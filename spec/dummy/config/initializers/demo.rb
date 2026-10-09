# Configuration only the demo needs. The engine's specs boot without the demo
# (see config.x.demo in config/application.rb), so nothing here reaches them.
return unless Rails.configuration.x.demo

TudlaAccounting.configure do |config|
  # Demo Co's books span two years: last year's profit has to land in retained
  # earnings for this year's balance sheet to balance.
  #
  # The engine's settings are app-wide, so in development this applies to every
  # organization, not just Demo Co: any with a 3900 account takes each year's profit
  # into it. The engine's specs boot without the demo and run with the default (nil),
  # so year-end carrying behaves differently there than when clicking through the app.
  config.retained_earnings_account_code = "3900"
end

# The stand-in login shows the demo's button instead of listing Demo Co with the rest.
Rails.configuration.x.sign_in_partial = "demo/sessions/button"
Rails.configuration.x.sign_in_organizations = ->(organizations) { organizations.where.not(name: Demo::Seeder::NAME) }
