require "rails_helper"
require_relative "../../support/configuration"

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

  describe "date boundaries" do
    it "allows a one-day period" do
      day = Time.zone.local(2026, 4, 15)
      expect(build(:tudla_accounting_period, from_date: day.beginning_of_day, thru_date: day.end_of_day)).to be_valid
    end

    it "includes every moment of its first and last day" do
      period = build(:tudla_accounting_period, from_date: Time.zone.local(2026, 4, 1), thru_date: Date.new(2026, 4, 30).end_of_day)

      expect(period.includes_date?(Date.new(2026, 4, 1))).to be(true)
      expect(period.includes_date?(Date.new(2026, 4, 30))).to be(true)
      expect(period.includes_date?(Time.zone.local(2026, 4, 30, 23, 59, 59))).to be(true)
      expect(period.includes_date?(Date.new(2026, 3, 31))).to be(false)
      expect(period.includes_date?(Time.zone.local(2026, 5, 1))).to be(false)
    end
  end

  describe "tree checks" do
    let(:organization) { create(:organization) }

    def period(from, thru, parent: nil)
      create(:tudla_accounting_period, organization: organization, parent: parent, from_date: from, thru_date: thru.end_of_day)
    end

    let(:q1) { period(Date.new(2026, 1, 1), Date.new(2026, 3, 31)) }

    describe ".ancestry_check" do
      it "is true for a root with no children" do
        expect(described_class.ancestry_check(q1)).to be(true)
      end

      it "is false for a non-root period" do
        jan = period(Date.new(2026, 1, 1), Date.new(2026, 1, 31), parent: q1)
        expect(described_class.ancestry_check(jan)).to be(false)
      end

      it "is false when a period has only one child" do
        period(Date.new(2026, 1, 1), Date.new(2026, 3, 31), parent: q1)
        expect(described_class.ancestry_check(q1)).to be(false)
      end

      it "is true when the children are contiguous and exactly cover the parent" do
        period(Date.new(2026, 1, 1), Date.new(2026, 1, 31), parent: q1)
        period(Date.new(2026, 2, 1), Date.new(2026, 2, 28), parent: q1)
        period(Date.new(2026, 3, 1), Date.new(2026, 3, 31), parent: q1)
        expect(described_class.ancestry_check(q1)).to be(true)
      end

      it "is false when there is a gap between children" do
        period(Date.new(2026, 1, 1), Date.new(2026, 1, 31), parent: q1)
        period(Date.new(2026, 3, 1), Date.new(2026, 3, 31), parent: q1)
        expect(described_class.ancestry_check(q1)).to be(false)
      end

      it "is false when the children do not reach the end of the parent" do
        period(Date.new(2026, 1, 1), Date.new(2026, 1, 31), parent: q1)
        period(Date.new(2026, 2, 1), Date.new(2026, 2, 28), parent: q1)
        expect(described_class.ancestry_check(q1)).to be(false)
      end

      it "is false when the children overlap" do
        period(Date.new(2026, 1, 1), Date.new(2026, 2, 15), parent: q1)
        period(Date.new(2026, 2, 1), Date.new(2026, 3, 31), parent: q1)
        expect(described_class.ancestry_check(q1)).to be(false)
      end

      it "checks every level of the tree" do
        year = period(Date.new(2026, 1, 1), Date.new(2026, 12, 31))
        q1 = period(Date.new(2026, 1, 1), Date.new(2026, 3, 31), parent: year)
        period(Date.new(2026, 4, 1), Date.new(2026, 12, 31), parent: year)
        period(Date.new(2026, 1, 1), Date.new(2026, 1, 31), parent: q1)
        jan_gap_feb = period(Date.new(2026, 2, 2), Date.new(2026, 3, 31), parent: q1)

        expect(described_class.ancestry_check(year)).to be(false)

        jan_gap_feb.update!(from_date: Time.zone.local(2026, 2, 1))
        expect(described_class.ancestry_check(year.reload)).to be(true)
      end
    end

    describe ".leaf_periods_for_date" do
      let!(:year) { period(Date.new(2026, 1, 1), Date.new(2026, 12, 31)) }
      let!(:h1) { period(Date.new(2026, 1, 1), Date.new(2026, 6, 30), parent: year) }
      let!(:h2) { period(Date.new(2026, 7, 1), Date.new(2026, 12, 31), parent: year) }

      it "returns only the childless period covering the date" do
        expect(described_class.leaf_periods_for_date(organization, Date.new(2026, 2, 15))).to contain_exactly(h1)
        expect(described_class.leaf_periods_for_date(organization, Date.new(2026, 10, 1))).to contain_exactly(h2)
      end

      it "returns the right period on the first and last day of each half" do
        expect(described_class.leaf_periods_for_date(organization, Date.new(2026, 6, 30))).to contain_exactly(h1)
        expect(described_class.leaf_periods_for_date(organization, Date.new(2026, 7, 1))).to contain_exactly(h2)
      end

      it "returns a root period that has no children" do
        other = create(:organization)
        lone = create(:tudla_accounting_period, organization: other, from_date: Time.zone.local(2030, 5, 1), thru_date: Date.new(2030, 5, 31).end_of_day)
        expect(described_class.leaf_periods_for_date(other, Date.new(2030, 5, 15))).to contain_exactly(lone)
      end

      it "returns the leaf period containing a moment in time" do
        expect(described_class.leaf_periods_for_date(organization, Time.zone.local(2026, 6, 30, 23, 59, 59))).to contain_exactly(h1)
        expect(described_class.leaf_periods_for_date(organization, Time.zone.local(2026, 7, 1))).to contain_exactly(h2)
      end

      it "returns nothing outside every period" do
        expect(described_class.leaf_periods_for_date(organization, Date.new(2027, 1, 1))).to be_empty
      end
    end
  end

  describe ".periods_for_date in a configured time zone" do
    include_context "with isolated TudlaAccounting configuration"

    it "treats a plain Date as that day in the configured zone, not Rails' Time.zone" do
      TudlaAccounting.configuration.time_zone = "America/New_York"
      organization = create(:organization)
      year = TudlaAccounting::PeriodCreator.call(organization, 2026)
      jan, feb = year.children.order(:from_date).first(2)

      expect(described_class.periods_for_date(organization, Date.new(2026, 2, 1))).to contain_exactly(year, feb)
      expect(described_class.periods_for_date(organization, Date.new(2026, 1, 31))).to contain_exactly(year, jan)
    end
  end

  describe "#deletable? and #destroy_with_subtree!" do
    let(:organization) { create(:organization) }
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

    it "removes the year and its months while nothing is posted" do
      expect(year.deletable?).to be(true)
      expect { year.destroy_with_subtree! }.to change(described_class, :count).by(-13)
    end

    it "refuses once a balance exists anywhere in it" do
      TudlaAccounting::Balance.get(create(:tudla_accounting_account, organization: organization), year.children.last)
      expect(year.deletable?).to be(false)
      expect { year.destroy_with_subtree! }.to raise_error(ActiveRecord::RecordNotDestroyed, "Only a period with no balances can be deleted")
    end
  end
end
