require "rails_helper"

RSpec.describe TudlaAccounting::ForeignExchange, type: :model do
  it "builds from the factory" do
    expect(build(:tudla_accounting_foreign_exchange)).to be_valid
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:detail).macro).to eq(:belongs_to) }
  end

  describe "monetized fields" do
    it "exposes foreign_amount as a Money object" do
      fx = create(:tudla_accounting_foreign_exchange, other_currency_cents: 12_500, other_currency: "EUR")
      expect(fx.foreign_amount).to be_a(Money)
      expect(fx.foreign_amount.cents).to eq(12_500)
      expect(fx.foreign_amount.currency.iso_code).to eq("EUR")
    end
  end

  it "stores rate at DECIMAL(24,8) precision" do
    fx = create(:tudla_accounting_foreign_exchange, rate: BigDecimal("1.23456789"))
    expect(fx.reload.rate).to eq(BigDecimal("1.23456789"))
  end
end
