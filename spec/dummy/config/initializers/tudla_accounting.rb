# The dummy app runs on the engine's defaults. Setting TUDLA_SPEC_BASE_CURRENCY
# boots it configured the way a host app would be, from an initializer;
# see spec/integration/money_configuration_spec.rb.
if ENV["TUDLA_SPEC_BASE_CURRENCY"]
  TudlaAccounting.configure do |config|
    config.base_currency = ENV["TUDLA_SPEC_BASE_CURRENCY"]
    config.rounding = BigDecimal::ROUND_HALF_EVEN
  end
end

# The engine shows the books of the organization the dummy app's stand-in login picked.
TudlaAccounting.configure do |config|
  config.current_organization = ->(controller) { controller.send(:current_organization) }
  # The dummy app has no users; audit events name the stand-in login instead.
  config.current_actor = ->(_controller) { "Demo user" }
end
