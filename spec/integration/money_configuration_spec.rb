require "rails_helper"
require "open3"
require_relative "../support/configuration"

RSpec.describe "money-rails configuration" do
  def money_settings = { currency: Money.default_currency.iso_code, rounding: Money.rounding_mode }

  it "applies the engine defaults (USD, round half up) when the host app configures nothing" do
    expect(money_settings).to eq(currency: "USD", rounding: BigDecimal::ROUND_HALF_UP)
  end

  # Engine initializers load before the host's, so this boots a fresh app process
  # with the settings made from a host initializer (spec/dummy/config/initializers).
  it "applies settings made in a host app initializer" do
    script = 'puts [Money.default_currency.iso_code, Money.rounding_mode, Monetize.parse("1100.00").currency.iso_code].join(",")'
    output, status = Open3.capture2e({ "RAILS_ENV" => "test", "TUDLA_SPEC_BASE_CURRENCY" => "AUD" },
                                     "bin/rails", "runner", script, chdir: TudlaAccounting::Engine.root.to_s)

    expect(status).to be_success, output
    expect(output.lines.last.strip).to eq("AUD,#{BigDecimal::ROUND_HALF_EVEN},AUD")
  end

  context "when configured at runtime" do
    include_context "with isolated TudlaAccounting configuration"

    before do
      TudlaAccounting.configure do |config|
        config.base_currency = "AUD"
        config.rounding = BigDecimal::ROUND_HALF_EVEN
      end
    end

    it "applies the settings to money-rails immediately" do
      expect(money_settings).to eq(currency: "AUD", rounding: BigDecimal::ROUND_HALF_EVEN)
      expect(Money.from_amount(BigDecimal("0.025")).cents).to eq(2)
    end

    it "reads amounts without a currency in the base currency" do
      org = create(:organization, currency: "AUD")
      create(:tudla_accounting_account, code: "1000", category: :asset, currency: "AUD", organization: org)
      create(:tudla_accounting_account, code: "4000", category: :income, currency: "AUD", organization: org)

      entry = TudlaAccounting::Entry.create_from_ruby_hash(
        organization_type: "Organization", organization_id: org.id, particulars: "Sale", transacted_at: "2026-03-10T09:00:00Z",
        details: [ { account_code: "1000", amount: "1100.00" }, { account_code: "4000", amount: "1100.00" } ]
      )

      expect(entry.details.map(&:amount)).to all(eq(Money.new(1100_00, "AUD")))
    end
  end

  it "restores money-rails defaults after an isolated configuration change" do
    expect(money_settings).to eq(currency: "USD", rounding: BigDecimal::ROUND_HALF_UP)
  end
end
