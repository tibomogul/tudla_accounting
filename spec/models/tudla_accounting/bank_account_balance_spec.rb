require "rails_helper"

RSpec.describe TudlaAccounting::BankAccountBalance, type: :model do
  it "builds from the factory" do
    expect(build(:tudla_accounting_bank_account_balance)).to be_valid
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:account).macro).to eq(:belongs_to) }
  end

  describe "monetized fields" do
    it "exposes balance as a Money object" do
      bab = create(:tudla_accounting_bank_account_balance, balance_cents: 50_000, currency: "USD")
      expect(bab.balance).to be_a(Money)
      expect(bab.balance.cents).to eq(50_000)
    end
  end
end
