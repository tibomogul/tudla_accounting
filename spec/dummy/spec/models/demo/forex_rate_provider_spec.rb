require "rails_helper"

RSpec.describe Demo::ForexRateProvider do
  subject(:provider) { described_class.new }

  it "gives a dollar–euro rate near 0.92 for any date, and its inverse" do
    rates = (Date.new(2020, 1, 1)..Date.new(2030, 12, 31)).step(37).map { |date| provider.call(from: "USD", to: "EUR", date: date) }
    expect(rates).to all(be_between(BigDecimal("0.90"), BigDecimal("0.94")))
    expect(rates.uniq.size).to be > 10
    date = Date.new(2026, 11, 2)
    expect(provider.call(from: "EUR", to: "USD", date: date)).to eq((1 / provider.call(from: "USD", to: "EUR", date: date)).round(4))
    expect(provider.call(from: "GBP", to: "EUR", date: date)).to be_nil
  end

  it "is the demo's provider, so a dollar invoice left without a rate gets the day's" do
    expect(TudlaAccounting.configuration.forex_rate_provider).to be_a(described_class)
    travel_to(Time.zone.local(2026, 6, 15, 9)) do
      books = Demo::EuroSeeder.call(entries: 10)
      acme = TudlaAccounting::Contact.find_by!(organization: books, name: "Acme Inc.")
      invoice = TudlaAccounting::Document.create!(organization: books, kind: "sales_invoice", contact: acme, issued_on: Date.current, currency: "USD",
                                                  lines_attributes: [ { description: "Work", quantity: 1, unit_price_cents: 100_00, account: acme.default_account } ])
      expect(invoice.exchange_rate).to eq(provider.call(from: "USD", to: "EUR", date: Date.current))
    end
  end
end
