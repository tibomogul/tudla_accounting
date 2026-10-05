require "rails_helper"

# Exercised through Period, the only model that includes the concern. Ranges are
# inclusive and are expected to run from the start of their first day to the end
# of their last day (as PeriodCreator builds them).
RSpec.describe TudlaAccounting::DatetimeRange do
  let(:klass) { TudlaAccounting::Period }

  def range(from, thru) = klass.new(from_date: from.beginning_of_day, thru_date: thru.end_of_day)

  let(:jan) { range(Date.new(2026, 1, 1), Date.new(2026, 1, 31)) }
  let(:feb) { range(Date.new(2026, 2, 1), Date.new(2026, 2, 28)) }
  let(:mar) { range(Date.new(2026, 3, 1), Date.new(2026, 3, 31)) }
  let(:q1) { range(Date.new(2026, 1, 1), Date.new(2026, 3, 31)) }
  let(:mid_jan_to_mid_feb) { range(Date.new(2026, 1, 15), Date.new(2026, 2, 15)) }

  describe "#<=>" do
    it "orders by from_date, then thru_date" do
      expect([ mar, q1, feb, jan ].sort).to eq([ jan, q1, feb, mar ])
    end
  end

  describe "#includes_date?" do
    it "is inclusive of both ends" do
      expect(jan.includes_date?(Time.zone.local(2026, 1, 1))).to be(true)
      expect(jan.includes_date?(Time.zone.local(2026, 1, 31, 23, 59, 59))).to be(true)
      expect(jan.includes_date?(Time.zone.local(2026, 2, 1))).to be(false)
    end
  end

  describe "#includes_dates? and #includes_other?" do
    it "is true only when the whole span is inside" do
      expect(q1.includes_dates?(feb.from_date, feb.thru_date)).to be(true)
      expect(q1.includes_other?(feb)).to be(true)
      expect(feb.includes_other?(q1)).to be(false)
      expect(jan.includes_other?(mid_jan_to_mid_feb)).to be(false)
    end
  end

  describe "#equals?" do
    it "compares both ends" do
      expect(jan.equals?(range(Date.new(2026, 1, 1), Date.new(2026, 1, 31)))).to be(true)
      expect(jan.equals?(range(Date.new(2026, 1, 1), Date.new(2026, 1, 30)))).to be(false)
    end
  end

  describe "#overlaps? and #overlaps_dates?" do
    it "detects partial overlap, containment in either direction, and nothing for adjacent ranges" do
      expect(jan.overlaps?(mid_jan_to_mid_feb)).to be(true)
      expect(jan.overlaps?(q1)).to be(true)
      expect(q1.overlaps?(jan)).to be(true)
      expect(jan.overlaps?(feb)).to be(false)
      expect(jan.overlaps?(mar)).to be(false)
    end

    it "works the same against a raw pair of times" do
      expect(jan.overlaps_dates?(mid_jan_to_mid_feb.from_date, mid_jan_to_mid_feb.thru_date)).to be(true)
      expect(jan.overlaps_dates?(q1.from_date, q1.thru_date)).to be(true)
      expect(jan.overlaps_dates?(feb.from_date, feb.thru_date)).to be(false)
    end
  end

  describe "#gap" do
    it "returns the uncovered span between two separated ranges, in either order" do
      gap = jan.gap(mar)
      expect(gap.begin.to_date).to eq(Date.new(2026, 2, 1))
      expect(gap.end.to_date).to eq(Date.new(2026, 2, 28))
      expect(mar.gap(jan)).to eq(gap)
    end

    it "is nil for adjacent or overlapping ranges" do
      expect(jan.gap(feb)).to be_nil
      expect(jan.gap(mid_jan_to_mid_feb)).to be_nil
    end
  end

  describe "#abuts?" do
    it "is true only for ranges that touch without overlapping" do
      expect(jan.abuts?(feb)).to be(true)
      expect(feb.abuts?(jan)).to be(true)
      expect(jan.abuts?(mar)).to be(false)
      expect(jan.abuts?(mid_jan_to_mid_feb)).to be(false)
    end

    # gap/abuts? step one *second* past thru_date, so a range that ends at midnight
    # (thru_date: Date.new(2026, 1, 31)) leaves its whole last day uncovered.
    it "does not treat a range ending at midnight as touching the next day" do
      jan_to_midnight = klass.new(from_date: Time.zone.local(2026, 1, 1), thru_date: Time.zone.local(2026, 1, 31))
      expect(jan_to_midnight.abuts?(feb)).to be(false)
    end
  end

  describe ".is_contiguous?" do
    it "is true when each range abuts the next, regardless of input order" do
      expect(klass.is_contiguous?([ mar, jan, feb ])).to be(true)
      expect(klass.is_contiguous?([ jan ])).to be(true)
    end

    it "is false with a gap or an overlap" do
      expect(klass.is_contiguous?([ jan, mar ])).to be(false)
      expect(klass.is_contiguous?([ jan, mid_jan_to_mid_feb ])).to be(false)
    end

    it "is nil for an empty collection" do
      expect(klass.is_contiguous?([])).to be_nil
    end
  end

  describe ".combination" do
    it "spans contiguous ranges from the earliest start to the latest end" do
      combined = klass.combination([ mar, jan, feb ])
      expect(combined).to be_a(klass).and(have_attributes(from_date: q1.from_date, thru_date: q1.thru_date))
    end

    it "is nil for non-contiguous or empty collections" do
      expect(klass.combination([ jan, mar ])).to be_nil
      expect(klass.combination([])).to be_nil
    end
  end

  describe "#partitioned_by?" do
    it "is true when at least two contiguous ranges exactly cover it" do
      expect(q1.partitioned_by?([ feb, jan, mar ])).to be(true)
    end

    it "is false for a single range, a gap, an overlap, or an incomplete cover" do
      expect(jan.partitioned_by?([ jan ])).to be(false)
      expect(q1.partitioned_by?([ jan, mar ])).to be(false)
      expect(q1.partitioned_by?([ jan, mid_jan_to_mid_feb, mar ])).to be(false)
      expect(q1.partitioned_by?([ jan, feb ])).to be(false)
    end
  end

  describe ".includes_date? scope" do
    it "finds saved ranges covering a date, including their first and last day" do
      org = create(:organization)
      saved_jan = create(:tudla_accounting_period, organization: org, from_date: jan.from_date, thru_date: jan.thru_date)
      saved_feb = create(:tudla_accounting_period, organization: org, from_date: feb.from_date, thru_date: feb.thru_date)

      expect(klass.includes_date?(Date.new(2026, 1, 15))).to contain_exactly(saved_jan)
      expect(klass.includes_date?(Date.new(2026, 1, 31))).to contain_exactly(saved_jan)
      expect(klass.includes_date?(Date.new(2026, 2, 1))).to contain_exactly(saved_feb)
      expect(klass.includes_date?(Date.new(2025, 12, 31))).to be_empty
    end
  end
end
