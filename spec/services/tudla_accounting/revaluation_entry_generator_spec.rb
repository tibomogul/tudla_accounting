require "rails_helper"
require_relative "../../support/entry_sources"

RSpec.describe TudlaAccounting::RevaluationEntryGenerator, type: :service do
  include_context "with entry source models"

  let(:organization) { create(:organization, currency: "AUD") }
  let(:period_end) { Date.new(2026, 3, 31) }
  let(:next_start) { Date.new(2026, 4, 1) }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:march) { year.children.order(:from_date).third }
  let(:april) { year.children.order(:from_date).fourth }

  before do
    TudlaAccounting.configuration.unrealized_fx_gain_account_code = "4900"
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash", category: "asset" },
      { code: "1100", name: "Accounts Receivable", category: "asset", children: [
        { code: "1100-EUR", name: "Accounts Receivable - EUR", category: "asset", currency: "EUR" } ] },
      { code: "2100", name: "Accounts Payable", category: "liability", children: [
        { code: "2100-EUR", name: "Accounts Payable - EUR", category: "liability", currency: "EUR" } ] },
      { code: "4000", name: "Sales", category: "income" },
      { code: "4900", name: "Unrealized FX Gain", category: "income" },
      { code: "5000", name: "Purchases", category: "expense" }
    ], organization)
  end

  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def balance(code, period) = TudlaAccounting::Balance.get(account(code), period)
  def eur_rate(rate, on: period_end) = TudlaAccounting::ForexRate.create!(from: "EUR", to: "AUD", year: on.year, month: on.month, day: on.day, rate: BigDecimal(rate))

  def post(lines, on:, **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: on, **attrs)
    lines.each do |code, tally, amount, fx|
      line = entry.details.build(account: account(code), tally: tally, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
      line.build_foreign_exchange(other_currency: "EUR", other_currency_cents: fx[0] * 100, rate: BigDecimal(fx[1])) if fx
    end
    entry.save!
    entry.post(on)
    entry
  end

  def eur_invoice(eur, rate, on: Time.zone.local(2026, 3, 10))
    post([ [ "1100-EUR", :debit, eur * BigDecimal(rate), [ eur, rate ] ], [ "4000", :credit, eur * BigDecimal(rate) ] ],
         on: on, source: Invoice.create!(due_date: on + 30.days))
  end

  def eur_bill(eur, rate)
    post([ [ "5000", :debit, eur * BigDecimal(rate) ], [ "2100-EUR", :credit, eur * BigDecimal(rate), [ eur, rate ] ] ],
         on: Time.zone.local(2026, 3, 12), source: Bill.create!(due_date: Time.zone.local(2026, 4, 30)))
  end

  def run = described_class.call(organization, period_end, next_start)

  it "books an unrealized gain on a receivable at period end, debiting the receivable, and reverses it next period" do
    invoice = eur_invoice(100, "1.54") # 154.00 AUD
    eur_rate("1.60")                   # now worth 160.00 AUD

    revaluation, reversal = run

    expect(revaluation).to have_attributes(particulars: "Revaluation of Accounts Receivable - EUR", related: invoice,
                                           transacted_at: Time.zone.local(2026, 3, 31), posted_at: Time.zone.local(2026, 3, 31))
    expect(revaluation.details.map { |d| [ d.account.code, d.tally, d.amount ] }).to contain_exactly([ "1100-EUR", "debit", aud(6) ], [ "4900", "credit", aud(6) ])
    expect(reversal.details.map { |d| [ d.account.code, d.tally, d.amount ] }).to contain_exactly([ "1100-EUR", "credit", aud(6) ], [ "4900", "debit", aud(6) ])
    expect(reversal).to have_attributes(particulars: "Reversal of Revaluation of Accounts Receivable - EUR", transacted_at: Time.zone.local(2026, 4, 1))

    expect(balance("1100-EUR", march).ending_amount).to eq(aud(160))
    expect(balance("4900", march).ending_amount).to eq(aud(6))
    expect(balance("1100-EUR", april).ending_amount).to eq(aud(154))
    expect(balance("4900", april).current_amount).to eq(aud(-6))
  end

  it "books an unrealized loss on a payable when the foreign currency strengthens" do
    eur_bill(50, "1.55") # 77.50 AUD
    eur_rate("1.60")     # now owe 80.00 AUD

    revaluation, = run

    expect(revaluation.details.map { |d| [ d.account.code, d.tally, d.amount ] }).to contain_exactly([ "2100-EUR", "credit", aud(2.5) ], [ "4900", "debit", aud(2.5) ])
    expect(balance("2100-EUR", march).ending_amount).to eq(aud(80))
  end

  it "books a loss on a receivable when the foreign currency weakens" do
    eur_invoice(100, "1.54")
    eur_rate("1.50")

    revaluation, = run
    expect(revaluation.details.map { |d| [ d.account.code, d.tally, d.amount ] }).to contain_exactly([ "1100-EUR", "credit", aud(4) ], [ "4900", "debit", aud(4) ])
  end

  it "does not open carrying amounts for the revaluation entries" do
    eur_invoice(100, "1.54")
    eur_rate("1.60")
    expect { run }.not_to change(TudlaAccounting::CarryingAmount, :count)
  end

  it "revalues only what is still owed in the foreign currency" do
    invoice = eur_invoice(100, "1.54")
    post([ [ "1000", :debit, "61.60" ], [ "1100-EUR", :credit, "61.60", [ 40, "1.54" ] ] ], on: Time.zone.local(2026, 3, 20),
         source: Payment.create!, related: invoice) # 40 EUR paid: 60 EUR (92.40 AUD) left
    eur_rate("1.60")

    revaluation, = run
    expect(revaluation.details.find { |d| d.account.code == "4900" }.amount).to eq(aud("3.60")) # 60 x 1.60 = 96.00
  end

  it "skips amounts that have not moved, are fully settled, or were booked after the period end" do
    eur_invoice(100, "1.60")
    settled = eur_invoice(10, "1.54")
    post([ [ "1000", :debit, "15.40" ], [ "1100-EUR", :credit, "15.40", [ 10, "1.54" ] ] ], on: Time.zone.local(2026, 3, 20),
         source: Payment.create!, related: settled)
    eur_invoice(10, "1.54", on: Time.zone.local(2026, 4, 2))
    eur_rate("1.60")

    expect(run).to eq([])
  end

  it "does nothing more when run again for the same date" do
    eur_invoice(100, "1.54")
    eur_rate("1.60")
    run
    expect { expect(run).to eq([]) }.not_to change(TudlaAccounting::Entry, :count)
  end

  it "only revalues the organization's own amounts" do
    eur_invoice(100, "1.54")
    eur_rate("1.60")
    other = create(:organization, currency: "AUD")
    expect(described_class.call(other, period_end, next_start)).to eq([])
  end

  it "creates nothing if a rate is missing" do
    eur_invoice(100, "1.54")
    expect { run }.to raise_error(TudlaAccounting::ForexRateRetriever::RateNotFound)
    expect(TudlaAccounting::Entry.where(particulars: "Revaluation of Accounts Receivable - EUR")).to be_empty
  end

  it "needs the unrealized gain account configured" do
    TudlaAccounting.configuration.unrealized_fx_gain_account_code = nil
    expect { run }.to raise_error(ArgumentError, "TudlaAccounting.configuration.unrealized_fx_gain_account_code is not set")
  end
end
