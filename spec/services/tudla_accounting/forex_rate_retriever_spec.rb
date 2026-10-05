require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe TudlaAccounting::ForexRateRetriever, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:date) { Date.new(2026, 3, 31) }

  def rate(from, to) = described_class.call(from: from, to: to, date: date)
  def store(from, to, value) = TudlaAccounting::ForexRate.create!(from: from, to: to, year: 2026, month: 3, day: 31, rate: BigDecimal(value))

  it "is 1 between a currency and itself" do
    expect(rate("AUD", "aud")).to eq(1)
  end

  it "uses a stored rate, or the inverse of the opposite one" do
    store("EUR", "AUD", "1.6")
    expect(rate("EUR", "AUD")).to eq(BigDecimal("1.6"))
    expect(rate("AUD", "EUR")).to eq(BigDecimal("0.625"))
  end

  it "asks the provider for a missing rate and stores it" do
    provider = ->(from:, to:, date:) { from == "EUR" && to == "AUD" && date == Date.new(2026, 3, 31) ? 1.6 : nil }
    TudlaAccounting.configuration.forex_rate_provider = provider

    expect(rate("EUR", "AUD")).to eq(BigDecimal("1.6"))
    expect(TudlaAccounting::ForexRate.find_by(from: "EUR", to: "AUD", year: 2026, month: 3, day: 31).rate).to eq(BigDecimal("1.6"))

    TudlaAccounting.configuration.forex_rate_provider = ->(**) { raise "should use the stored rate" }
    expect(rate("EUR", "AUD")).to eq(BigDecimal("1.6"))
  end

  it "raises when there is no provider, or the provider has no rate" do
    expect { rate("EUR", "AUD") }.to raise_error(described_class::RateNotFound, "No EUR/AUD rate for 2026-03-31 and no forex_rate_provider configured")
    TudlaAccounting.configuration.forex_rate_provider = ->(**) { nil }
    expect { rate("EUR", "AUD") }.to raise_error(described_class::RateNotFound, "No EUR/AUD rate for 2026-03-31")
  end
end
