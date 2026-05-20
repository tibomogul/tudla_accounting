require "rails_helper"

RSpec.describe TudlaAccounting::Period, type: :model do
  it "builds from the factory" do
    expect(build(:tudla_accounting_period)).to be_valid
  end

  describe "validations" do
    it "requires from_date and thru_date" do
      period = TudlaAccounting::Period.new
      period.valid?
      expect(period.errors[:from_date]).to be_present
      expect(period.errors[:thru_date]).to be_present
    end

    it "requires thru_date to be greater than from_date" do
      period = build(:tudla_accounting_period, from_date: Time.current, thru_date: 1.day.ago)
      expect(period).not_to be_valid
      expect(period.errors[:thru_date]).to include("should be greater than from date")
    end
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:organization).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:balances).macro).to eq(:has_many) }
  end

  describe "DatetimeRange concern" do
    it "includes TudlaAccounting::DatetimeRange" do
      expect(described_class.included_modules).to include(TudlaAccounting::DatetimeRange)
    end
  end
end
