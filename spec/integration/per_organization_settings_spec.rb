require "rails_helper"
require_relative "../support/configuration"

# Settings that can differ by organization (Configuration::PER_ORGANIZATION), as a
# bookkeeper's app keeping several clients' books might set them.
RSpec.describe "Per-organization settings" do
  include_context "with isolated TudlaAccounting configuration"

  let(:even) { create(:organization, name: "Even Books", currency: "AUD") }
  let(:up) { create(:organization, name: "Up Books", currency: "AUD") }

  before do
    TudlaAccounting.configuration.rounding = ->(organization) { organization == even ? BigDecimal::ROUND_HALF_EVEN : BigDecimal::ROUND_HALF_UP }
    TudlaAccounting.configuration.tax_basis = ->(organization) { organization == even ? :cash : :accrual }
  end

  it "rounds each organization's tax, imports and conversions its own way" do
    expect([ even, up ].map { |books| TudlaAccounting::TaxCode.new(organization: books, rate: "0.1").tax_cents(25) }).to eq([ 2, 3 ])
    expect([ even, up ].map { |books| TudlaAccounting::AmountParser.cents("10.005", "AUD", round: books) }).to eq([ 10_00, 10_01 ])
    expect([ even, up ].map { |books| TudlaAccounting.money(BigDecimal("0.125"), "AUD", books).cents }).to eq([ 12, 13 ])
    expect(TudlaAccounting::AmountParser.cents("10.00", "AUD")).to eq(10_00) # nothing to round, so no organization needed
    expect { TudlaAccounting::AmountParser.cents("10.005", "AUD", round: true) }.to raise_error(ArgumentError, /rounding setting is given the organization/)
  end

  it "counts each organization's tax on its own basis unless the report says" do
    report = ->(books, basis = nil) { TudlaAccounting::TaxReport.new(books, from: Time.zone.local(2026, 1, 1), thru: Time.zone.local(2026, 1, 31), basis: basis) }
    expect([ report.call(even).call[:basis], report.call(up).call[:basis], report.call(up, "cash").call[:basis] ]).to eq(%i[cash accrual cash])
  end
end
