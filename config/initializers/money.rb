# frozen_string_literal: true

MoneyRails.configure do |config|
  config.default_currency = Money::Currency.new(TudlaAccounting.configuration.base_currency)
  config.rounding_mode = TudlaAccounting.configuration.rounding
  config.locale_backend = :currency
end
