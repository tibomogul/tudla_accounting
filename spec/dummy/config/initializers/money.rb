# The dummy app's own money-rails defaults, as a host app might have them: unlike the
# engine's settings (base_currency USD, rounding half up), so the suite shows the engine
# passes its currency and rounding itself rather than relying on Money's globals.
MoneyRails.configure do |money|
  money.default_currency = :jpy
  money.rounding_mode = BigDecimal::ROUND_DOWN
  money.locale_backend = :i18n
end
