require "rails_helper"

RSpec.describe TudlaAccounting::Balance, type: :model do
  it "builds from the factory" do
    expect(build(:tudla_accounting_balance)).to be_valid
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:organization).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:account).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:period).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:details).macro).to eq(:has_many) }
  end

  describe "monetized fields" do
    it "exposes starting/current/ending amounts as Money objects" do
      balance = create(:tudla_accounting_balance, starting_amount_cents: 1_000, current_amount_cents: 2_000, ending_amount_cents: 3_000)
      expect(balance.starting_amount).to be_a(Money)
      expect(balance.current_amount).to be_a(Money)
      expect(balance.ending_amount).to be_a(Money)
      expect(balance.starting_amount.cents).to eq(1_000)
    end
  end
end
