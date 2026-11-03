require "rails_helper"

RSpec.describe TudlaAccounting::FilingQuarters, type: :service do
  let(:organization) { create(:organization, currency: "PHP") }

  it "counts quarters from January for a day no financial year covers" do
    quarter = described_class.new(organization).of(Date.new(2026, 5, 3))
    expect(quarter).to have_attributes(from: Date.new(2026, 4, 1), thru: Date.new(2026, 6, 30), label: "Apr–Jun 2026", range: Date.new(2026, 4, 1)..Date.new(2026, 6, 30))
  end

  it "counts quarters from the start of the financial year" do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    expect(described_class.new(organization).of(Date.new(2026, 12, 31)).label).to eq("Oct–Dec 2026")
  end

  it "follows a financial year that doesn't start in January, across the turn of the calendar year" do
    year = instance_double(TudlaAccounting::Period, from_date: Time.zone.local(2026, 2, 1), thru_date: Time.zone.local(2027, 1, 31).end_of_day)
    allow(TudlaAccounting::Period).to receive(:where).and_return(class_double(TudlaAccounting::Period, roots: [ year ]))
    quarters = described_class.new(organization)
    expect(quarters.of(Date.new(2026, 2, 1))).to have_attributes(from: Date.new(2026, 2, 1), thru: Date.new(2026, 4, 30))
    expect(quarters.of(Date.new(2027, 1, 15))).to have_attributes(from: Date.new(2026, 11, 1), thru: Date.new(2027, 1, 31), label: "Nov 2026–Jan 2027")
  end
end
