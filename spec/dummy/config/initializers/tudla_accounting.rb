# The dummy app runs on the engine's defaults. Setting TUDLA_SPEC_BASE_CURRENCY
# boots it configured the way a host app would be, from an initializer;
# see spec/integration/money_configuration_spec.rb.
if ENV["TUDLA_SPEC_BASE_CURRENCY"]
  TudlaAccounting.configure do |config|
    config.base_currency = ENV["TUDLA_SPEC_BASE_CURRENCY"]
    config.rounding = BigDecimal::ROUND_HALF_EVEN
  end
end
