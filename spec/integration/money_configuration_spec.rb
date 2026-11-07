require "rails_helper"
require_relative "../support/configuration"

# The dummy app sets its own money-rails defaults (config/initializers/money.rb: the yen,
# rounding down, the i18n backend), unlike the engine's settings, as a host app might.
RSpec.describe "money-rails configuration" do
  include_context "with isolated TudlaAccounting configuration"

  def money_settings = { currency: Money.default_currency.iso_code, rounding: Money.rounding_mode, backend: Money.locale_backend.class }

  it "leaves the host app's money-rails defaults as they are" do
    host = { currency: "JPY", rounding: BigDecimal::ROUND_DOWN, backend: Money::LocaleBackend::I18n }
    expect(money_settings).to eq(host)
    TudlaAccounting.configure do |config|
      config.base_currency = "AUD"
      config.rounding = BigDecimal::ROUND_HALF_EVEN
    end
    expect(money_settings).to eq(host)
  end

  it "rounds amounts in the rounding setting's mode, not Money's" do
    expect(TudlaAccounting::AmountParser.cents("10.005", "AUD", round: true)).to eq(10_01)
    TudlaAccounting.configuration.rounding = BigDecimal::ROUND_HALF_EVEN
    expect(TudlaAccounting::AmountParser.cents("10.005", "AUD", round: true)).to eq(10_00)
    expect(TudlaAccounting::AmountParser.cents("10.015", "AUD", round: true)).to eq(10_02)
    expect(Money.rounding_mode).to eq(BigDecimal::ROUND_DOWN)
    expect { TudlaAccounting.money(1, nil) }.to raise_error(ArgumentError, "currency is missing")
  end

  it "reads amounts without a currency in the organization's currency, not Money's default" do
    org = create(:organization, currency: "NZD")
    create(:tudla_accounting_account, code: "1000", category: :asset, currency: "NZD", organization: org)
    create(:tudla_accounting_account, code: "4000", category: :income, currency: "NZD", organization: org)

    entry = TudlaAccounting::Entry.create_from_ruby_hash(
      organization_type: "Organization", organization_id: org.id, particulars: "Sale", transacted_at: "2026-03-10T09:00:00Z",
      details: [ { account_code: "1000", amount: "1100.00" }, { account_code: "4000", amount: "1100.00" } ]
    )

    expect(entry.details.map(&:amount)).to all(eq(Money.new(1100_00, "NZD")))
  end
end
