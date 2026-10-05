require "rails_helper"

RSpec.describe TudlaAccounting::ForexGainOrLossCalculator, type: :service do
  let(:organization) { create(:organization, currency: "AUD") }
  let(:date) { Date.new(2026, 3, 31) }
  let(:detail) { create(:tudla_accounting_detail, organization: organization, currency: "AUD") }

  def carrying_amount(type)
    create(:tudla_accounting_carrying_amount, detail: detail, carrying_amount_type: type).tap do |amount|
      amount.create_forex!(other_currency: "EUR", other_currency_amount_cents: 1000_00, transaction_rate: BigDecimal("1.5"))
    end
  end

  def calculate(rate, type)
    TudlaAccounting::ForexRate.create!(from: "EUR", to: "AUD", year: 2026, month: 3, day: 31, rate: BigDecimal(rate))
    described_class.call(amount: Money.from_amount(1000, "EUR"), conversion_date: date, carrying_amount: carrying_amount(type))
  end

  it "is a gain on a receivable when the foreign currency strengthens, in the organization's currency" do
    expect(calculate("1.6", :receivable)).to eq(Money.from_amount(100, "AUD"))
  end

  it "is a loss on a receivable when it weakens" do
    expect(calculate("1.4", :receivable)).to eq(Money.from_amount(-100, "AUD"))
  end

  it "is the opposite on a payable" do
    expect(calculate("1.6", :payable)).to eq(Money.from_amount(-100, "AUD"))
  end

  it "is zero when the rate has not moved" do
    expect(calculate("1.5", :receivable)).to be_zero
  end

  it "accepts a BigDecimal amount" do
    TudlaAccounting::ForexRate.create!(from: "EUR", to: "AUD", year: 2026, month: 3, day: 31, rate: BigDecimal("1.6"))
    expect(described_class.call(amount: BigDecimal("1000"), conversion_date: date, carrying_amount: carrying_amount(:receivable)))
      .to eq(Money.from_amount(100, "AUD"))
  end

  it "validates its arguments" do
    amount = Money.from_amount(1, "EUR")
    plain = create(:tudla_accounting_carrying_amount, detail: detail)

    expect { described_class.call(amount: 1000, conversion_date: date, carrying_amount: plain) }.to raise_error(ArgumentError, "Amount must be a BigDecimal or Money")
    expect { described_class.call(amount: amount, conversion_date: "2026-03-31", carrying_amount: plain) }.to raise_error(ArgumentError, "conversion_date must be a Date")
    expect { described_class.call(amount: amount, conversion_date: date, carrying_amount: double) }
      .to raise_error(ArgumentError, "carrying_amount must be a TudlaAccounting::CarryingAmount")
    expect { described_class.call(amount: amount, conversion_date: date, carrying_amount: plain) }
      .to raise_error(ArgumentError, "CarryingAmount must have a foreign exchange record")
  end
end
