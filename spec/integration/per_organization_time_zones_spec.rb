require "rails_helper"
require_relative "../support/configuration"

# The time_zone setting given per organization: books kept far apart, on either side of
# the date line (Kiritimati is UTC+14, Pago Pago UTC-11).
RSpec.describe "Per-organization time zones" do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:east) { create(:organization, name: "East Books", currency: "USD") }
  let(:west) { create(:organization, name: "West Books", currency: "USD") }

  before { TudlaAccounting.configuration.time_zone = ->(books) { books == east ? "Pacific/Kiritimati" : "Pacific/Pago_Pago" } }
  after { travel_back }

  def months(books) = TudlaAccounting::Period.where(organization: books).where.not(ancestry: "/").order(:from_date)

  it "builds each organization's years and months from its own midnight, and finds a day's period there" do
    [ east, west ].each { |books| TudlaAccounting::PeriodCreator.call(books, 2026) }

    expect(months(east).first.from_date).to eq(Time.utc(2025, 12, 31, 10))
    expect(months(west).first.from_date).to eq(Time.utc(2026, 1, 1, 11))
    [ east, west ].each do |books|
      expect(TudlaAccounting::Period.leaf_periods_for_date(books, Date.new(2026, 3, 1)).map { |month| month.from_date.in_time_zone(TudlaAccounting.zone(books)).to_date })
        .to eq([ Date.new(2026, 3, 1) ])
    end
  end

  it "won't add a year once the organization's zone has changed under its periods" do
    TudlaAccounting::PeriodCreator.call(east, 2026)
    TudlaAccounting.configuration.time_zone = "UTC"
    expect { TudlaAccounting::PeriodCreator.call(east, 2027) }
      .to raise_error(TudlaAccounting::PeriodInvalid, "The books' years start at midnight in another time zone than Etc/UTC: the time_zone setting changed after they were made")
  end

  it "runs what is due by the day it is in each organization's zone" do
    travel_to Time.utc(2026, 3, 1, 12) # 2 March in the east, still 1 March in the west
    templates = [ east, west ].to_h do |books|
      TudlaAccounting::PeriodCreator.call(books, 2026)
      TudlaAccounting::AccountsCreator.call([ { code: "1010", name: "Cash", category: "asset" }, { code: "6100", name: "Rent", category: "expense" } ], books)
      account = ->(code) { TudlaAccounting::Account.find_by!(organization: books, code: code) }
      template = TudlaAccounting::RecurringEntry.new(organization: books, name: "Rent", particulars: "Rent", frequency: "monthly", starts_on: Date.new(2026, 3, 2), day_of_month: 2)
      template.lines.build(account: account.call("6100"), tally: :debit, amount_cents: 100_00)
      template.lines.build(account: account.call("1010"), tally: :credit, amount_cents: 100_00)
      template.save!
      [ books, template ]
    end

    made = TudlaAccounting::RecurringEntryRunner.call.created
    expect(made.map(&:organization)).to eq([ east ])
    expect(templates[west].reload.next_on).to eq(Date.new(2026, 3, 2))
    expect([ east, west ].map { |books| TudlaAccounting.zone(books).today }).to eq([ Date.new(2026, 3, 2), Date.new(2026, 3, 1) ])
  end

  it "expires an API token at the end of its day in the organization's zone" do
    travel_to Time.utc(2026, 3, 1, 12)
    secrets = [ east, west ].map { |books| TudlaAccounting::ApiToken.issue!(organization: books, name: "Shop", permissions: %w[read], expires_on: Date.new(2026, 3, 1)).last }
    expect(secrets.map { |secret| TudlaAccounting::ApiToken.authenticate(secret)&.organization }).to eq([ nil, west ])
  end

  it "refuses a zone it doesn't know" do
    TudlaAccounting.configuration.time_zone = "Mars/Olympus"
    expect { TudlaAccounting.zone(east) }.to raise_error(ArgumentError, /time_zone gave "Mars\/Olympus" for .*; expected a zone such as "Australia\/Sydney"/)
  end
end
