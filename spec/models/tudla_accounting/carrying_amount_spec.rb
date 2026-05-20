require "rails_helper"

RSpec.describe TudlaAccounting::CarryingAmount, type: :model do
  it "builds from the factory" do
    expect(build(:tudla_accounting_carrying_amount)).to be_valid
  end

  describe "enums" do
    it "maps carrying_amount_type to receivable/payable integers" do
      expect(TudlaAccounting::CarryingAmount.carrying_amount_types).to eq("receivable" => 0, "payable" => 1)
    end
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:detail).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:related_party).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:forex).macro).to eq(:has_one) }
  end

  describe "#amount" do
    it "returns a Money object backed by the configured base currency" do
      carrying = create(:tudla_accounting_carrying_amount, amount_cents: 50_000)
      expect(carrying.amount).to be_a(Money)
      expect(carrying.amount.cents).to eq(50_000)
      expect(carrying.amount.currency.iso_code).to eq(TudlaAccounting.configuration.base_currency)
    end
  end
end
