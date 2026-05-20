require "rails_helper"

RSpec.describe TudlaAccounting::CarryingAmountForex, type: :model do
  it "builds from the factory" do
    expect(build(:tudla_accounting_carrying_amount_forex)).to be_valid
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:carrying_amount).macro).to eq(:belongs_to) }
  end

  it "stores transaction_rate at DECIMAL(24,8) precision" do
    forex = create(:tudla_accounting_carrying_amount_forex, transaction_rate: BigDecimal("1.23456789"))
    expect(forex.reload.transaction_rate).to eq(BigDecimal("1.23456789"))
  end
end
