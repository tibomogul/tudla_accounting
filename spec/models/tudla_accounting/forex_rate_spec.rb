require "rails_helper"

RSpec.describe TudlaAccounting::ForexRate, type: :model do
  it "builds from the factory" do
    expect(build(:tudla_accounting_forex_rate)).to be_valid
  end

  describe "validations" do
    it "requires from, to, rate, year, month, day" do
      forex = TudlaAccounting::ForexRate.new
      forex.valid?
      expect(forex.errors[:from]).to be_present
      expect(forex.errors[:to]).to be_present
      expect(forex.errors[:rate]).to be_present
      expect(forex.errors[:year]).to be_present
      expect(forex.errors[:month]).to be_present
      expect(forex.errors[:day]).to be_present
    end

    it "requires rate to be numeric" do
      forex = build(:tudla_accounting_forex_rate, rate: "not a number")
      expect(forex).not_to be_valid
      expect(forex.errors[:rate]).to be_present
    end

    it "requires year, month, day to be integers" do
      forex = build(:tudla_accounting_forex_rate, year: 1.5)
      expect(forex).not_to be_valid
      expect(forex.errors[:year]).to be_present
    end
  end

  it "stores rate at DECIMAL(24,8) precision" do
    forex = create(:tudla_accounting_forex_rate, rate: BigDecimal("0.12345678"))
    expect(forex.reload.rate).to eq(BigDecimal("0.12345678"))
  end
end
