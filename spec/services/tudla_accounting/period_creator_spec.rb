require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe TudlaAccounting::PeriodCreator, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization) }

  describe "#initialize" do
    it "accepts a year with an optional start month and day" do
      creator = described_class.new(organization, 2026, 7, 15)
      expect(creator).to have_attributes(organization: organization, year: 2026, start_month: 7, start_day: 15)
      expect(described_class.new(organization, 2026)).to have_attributes(start_month: 1, start_day: 1)
    end

    it "rejects a year below 1" do
      expect { described_class.new(organization, 0) }.to raise_error(TudlaAccounting::PeriodInvalid, "Year must be greater than 0")
    end

    it "rejects a start month outside 1..12" do
      [ 0, 13 ].each do |month|
        expect { described_class.new(organization, 2026, month) }
          .to raise_error(TudlaAccounting::PeriodInvalid, "Start month must be between 1 and 12")
      end
    end

    it "rejects a start day outside 1..28" do
      [ 0, 29 ].each do |day|
        expect { described_class.new(organization, 2026, 1, day) }
          .to raise_error(TudlaAccounting::PeriodInvalid, "Start day must be between 1 and 28")
      end
    end
  end

  describe "#call" do
    it "creates a calendar year with twelve months and returns the root" do
      root = nil
      expect { root = described_class.call(organization, 2026) }.to change(TudlaAccounting::Period, :count).by(13)

      expect(root).to have_attributes(parent: nil, organization: organization,
                                      from_date: Time.zone.local(2026, 1, 1), thru_date: Time.zone.local(2026, 12, 31).end_of_day.floor(6))

      months = root.children.order(:from_date)
      expect(months.size).to eq(12)
      expect(months.first).to have_attributes(from_date: Time.zone.local(2026, 1, 1), thru_date: Time.zone.local(2026, 1, 31).end_of_day.floor(6))
      expect(months.second.thru_date).to eq(Time.zone.local(2026, 2, 28).end_of_day.floor(6))
      expect(months.last).to have_attributes(from_date: Time.zone.local(2026, 12, 1), thru_date: Time.zone.local(2026, 12, 31).end_of_day.floor(6))
    end

    it "creates a fiscal year starting mid-year" do
      root = described_class.call(organization, 2026, 7, 15)
      months = root.children.order(:from_date)

      expect(root.from_date).to eq(Time.zone.local(2026, 7, 15))
      expect(root.thru_date).to eq(Time.zone.local(2027, 7, 14).end_of_day.floor(6))
      expect(months.first).to have_attributes(from_date: Time.zone.local(2026, 7, 15), thru_date: Time.zone.local(2026, 8, 14).end_of_day.floor(6))
      expect(months.last).to have_attributes(from_date: Time.zone.local(2027, 6, 15), thru_date: Time.zone.local(2027, 7, 14).end_of_day.floor(6))
    end

    it "uses the configured time zone for day boundaries" do
      TudlaAccounting.configuration.time_zone = "Australia/Brisbane" # UTC+10, no DST
      zone = ActiveSupport::TimeZone["Australia/Brisbane"]

      root = described_class.call(organization, 2026)

      expect(root.from_date).to eq(zone.local(2026, 1, 1))
      expect(root.from_date.utc).to eq(Time.utc(2025, 12, 31, 14))
      expect(root.thru_date).to eq(zone.local(2026, 12, 31).end_of_day.floor(6))
    end

    it "refuses a year overlapping one of the organization's years, but not another organization's" do
      described_class.call(organization, 2026)

      expect { described_class.call(organization, 2026, 7) }.to raise_error(TudlaAccounting::PeriodInvalid, "The year overlaps an existing financial year")
      expect { described_class.call(organization, 2025, 12, 31 - 3) }.to raise_error(TudlaAccounting::PeriodInvalid)
      expect(described_class.call(organization, 2027)).to be_present
      expect(described_class.call(create(:organization), 2026)).to be_present
    end

    it "produces a period tree that passes Period.ancestry_check" do
      expect(TudlaAccounting::Period.ancestry_check(described_class.call(organization, 2026))).to be(true)
    end

    it "creates nothing, logs, and returns nil if any period fails to save" do
      calls = 0
      allow(TudlaAccounting::Period).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
        calls += 1
        raise ActiveRecord::RecordInvalid, TudlaAccounting::Period.new if calls == 5

        original.call(*args, **kwargs)
      end
      allow(Rails.logger).to receive(:error)

      expect { expect(described_class.call(organization, 2026)).to be_nil }.not_to change(TudlaAccounting::Period, :count)
      expect(Rails.logger).to have_received(:error)
    end
  end
end
