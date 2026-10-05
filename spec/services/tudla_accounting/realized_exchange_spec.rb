require "rails_helper"
require_relative "../../support/entry_sources"

# Settling a foreign-currency invoice or bill at a different rate than it was booked at.
RSpec.describe "Realized exchange gains and losses", type: :service do
  include_context "with entry source models"

  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting.configuration.realized_fx_gain_account_code = "4950"
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash", category: "asset" },
      { code: "1100", name: "Accounts Receivable", category: "asset", children: [
        { code: "1100-EUR", name: "Accounts Receivable - EUR", category: "asset", currency: "EUR" } ] },
      { code: "2100", name: "Accounts Payable", category: "liability", children: [
        { code: "2100-EUR", name: "Accounts Payable - EUR", category: "liability", currency: "EUR" } ] },
      { code: "4000", name: "Sales", category: "income" },
      { code: "4950", name: "Realized FX Gain", category: "income" },
      { code: "5000", name: "Purchases", category: "expense" }
    ], organization)
  end

  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def balance(code) = TudlaAccounting::Balance.get(account(code), year).ending_amount

  def post(lines, on:, **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: attrs.delete(:particulars) || "Entry", transacted_at: on, **attrs)
    lines.each do |code, tally, amount, fx|
      line = entry.details.build(account: account(code), tally: tally, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
      line.build_foreign_exchange(other_currency: "EUR", other_currency_cents: (BigDecimal(fx[0].to_s) * 100).to_i, rate: BigDecimal(fx[1])) if fx
    end
    entry.save!
    entry.post(on)
    entry
  end

  def invoice(eur, rate)
    value = BigDecimal(eur.to_s) * BigDecimal(rate)
    post([ [ "1100-EUR", :debit, value, [ eur, rate ] ], [ "4000", :credit, value ] ], on: Time.zone.local(2026, 3, 10),
         particulars: "Invoice 1001", source: Invoice.create!(due_date: Time.zone.local(2026, 4, 9)))
  end

  def receive_payment(invoice_entry, eur, rate, on: Time.zone.local(2026, 4, 10))
    value = (BigDecimal(eur.to_s) * BigDecimal(rate)).round(2)
    post([ [ "1000", :debit, value ], [ "1100-EUR", :credit, value, [ eur, rate ] ] ], on: on, source: Payment.create!, related: invoice_entry)
  end

  def bill(eur, rate)
    value = BigDecimal(eur.to_s) * BigDecimal(rate)
    post([ [ "5000", :debit, value ], [ "2100-EUR", :credit, value, [ eur, rate ] ] ], on: Time.zone.local(2026, 3, 12),
         particulars: "Bill 2001", source: Bill.create!(due_date: Time.zone.local(2026, 4, 30)))
  end

  def pay(bill_entry, eur, rate)
    value = BigDecimal(eur.to_s) * BigDecimal(rate)
    post([ [ "2100-EUR", :debit, value, [ eur, rate ] ], [ "1000", :credit, value ] ], on: Time.zone.local(2026, 4, 20),
         source: Disbursement.create!, related: bill_entry)
  end

  def carrying_amount(entry, code) = entry.details.find_by(account: account(code)).carrying_amount

  it "books a gain when a receivable is paid at a higher rate, leaving nothing on the receivable" do
    inv = invoice(100, "1.54")
    payment = receive_payment(inv, 100, "1.60")

    realized = TudlaAccounting::Entry.find_by(related: payment)
    expect(realized).to have_attributes(particulars: "Realized exchange gain on Invoice 1001", transacted_at: payment.transacted_at, source: nil)
    expect(realized.posted_at).to be_present
    expect(realized.details.map { |d| [ d.account.code, d.tally, d.amount ] }).to contain_exactly([ "1100-EUR", "debit", aud(6) ], [ "4950", "credit", aud(6) ])

    expect(balance("1100-EUR")).to eq(aud(0))
    expect(balance("4950")).to eq(aud(6))
    expect(carrying_amount(inv, "1100-EUR")).to have_attributes(amount_cents: 0)
    expect(carrying_amount(inv, "1100-EUR").forex.other_currency_amount_cents).to eq(0)
  end

  it "books a loss when a receivable is paid at a lower rate" do
    inv = invoice(100, "1.54")
    receive_payment(inv, 100, "1.50")

    expect(balance("1100-EUR")).to eq(aud(0))
    expect(balance("4950")).to eq(aud(-4))
    expect(TudlaAccounting::Entry.find_by("particulars LIKE 'Realized%'").particulars).to eq("Realized exchange loss on Invoice 1001")
  end

  it "books a loss when a payable is paid at a higher rate, and a gain at a lower one" do
    dearer = bill(50, "1.55")   # 77.50
    pay(dearer, 50, "1.60")     # 80.00
    expect(balance("2100-EUR")).to eq(aud(0))
    expect(balance("4950")).to eq(aud(-2.5))

    cheaper = bill(50, "1.55")
    pay(cheaper, 50, "1.50")    # 75.00
    expect(balance("2100-EUR")).to eq(aud(0))
    expect(balance("4950")).to eq(aud(0))
  end

  def realized_lines(payment)
    entry = TudlaAccounting::Entry.find_by(related: payment)
    entry && [ entry.particulars, *entry.details.map { |d| [ d.account.code, d.tally, d.amount ] }.sort ]
  end

  it "books the gain or loss on each part payment's share, and on what remains at the final one" do
    inv = invoice(100, "1.54") # 154.00

    first = receive_payment(inv, 30, "1.60", on: Time.zone.local(2026, 4, 1))  # 30 x 1.54 = 46.20 booked, 48.00 paid
    second = receive_payment(inv, 30, "1.54", on: Time.zone.local(2026, 4, 2)) # paid at the booked rate
    last = receive_payment(inv, 40, "1.50", on: Time.zone.local(2026, 4, 3))   # the remaining 61.60 booked, 60.00 paid

    expect(realized_lines(first)).to eq([ "Realized exchange gain on Invoice 1001", [ "1100-EUR", "debit", aud(1.8) ], [ "4950", "credit", aud(1.8) ] ])
    expect(realized_lines(second)).to be_nil
    expect(realized_lines(last)).to eq([ "Realized exchange loss on Invoice 1001", [ "1100-EUR", "credit", aud(1.6) ], [ "4950", "debit", aud(1.6) ] ])
    expect(balance("1100-EUR")).to eq(aud(0))
    expect(balance("4950")).to eq(aud(0.2))
  end

  it "absorbs earlier rounding in the final payment, leaving no residue" do
    inv = invoice(100, "1.5437")            # 154.37
    receive_payment(inv, 33.33, "1.60")
    expect(carrying_amount(inv, "1100-EUR").amount_cents).to eq(154_37 - 51_45) # 33.33 x 1.5437 = 51.45
    receive_payment(inv, 66.67, "1.58", on: Time.zone.local(2026, 4, 20))

    expect(carrying_amount(inv, "1100-EUR")).to have_attributes(amount_cents: 0)
    expect(balance("1100-EUR")).to eq(aud(0))
    expect(balance("4950") + balance("4000")).to eq(balance("1000")) # cash received = sales + exchange gains
  end

  it "books the gain or loss only on what was owed, leaving an overpayment as a credit" do
    inv = invoice(100, "1.54")
    receive_payment(inv, 60, "1.54", on: Time.zone.local(2026, 4, 1)) # 40 EUR (61.60) left
    overpayment = receive_payment(inv, 50, "1.50", on: Time.zone.local(2026, 4, 2)) # 75.00 for 50 EUR: 10 EUR too many

    expect(realized_lines(overpayment)).to eq([ "Realized exchange loss on Invoice 1001", [ "1100-EUR", "credit", aud(1.6) ], [ "4950", "debit", aud(1.6) ] ])
    expect(balance("4950")).to eq(aud(-1.6))                       # 40 x (1.50 - 1.54)
    expect(balance("1100-EUR")).to eq(aud(-15))                    # 10 EUR at 1.50 owed back to the customer
    expect(carrying_amount(inv, "1100-EUR")).to have_attributes(amount_cents: -15_00)
    expect(carrying_amount(inv, "1100-EUR").forex.other_currency_amount_cents).to eq(-10_00)
  end

  it "treats a payment against an already settled amount as all overpayment" do
    inv = invoice(100, "1.54")
    receive_payment(inv, 100, "1.54", on: Time.zone.local(2026, 4, 1))
    extra = receive_payment(inv, 10, "1.60", on: Time.zone.local(2026, 4, 2))

    expect(realized_lines(extra)).to be_nil
    expect(balance("1100-EUR")).to eq(aud(-16))
  end

  it "posts nothing extra when the rate has not moved" do
    inv = invoice(100, "1.54")
    expect { receive_payment(inv, 100, "1.54") }.to change(TudlaAccounting::Entry, :count).by(1)
  end

  it "does not open or settle carrying amounts with the realized entry" do
    inv = invoice(100, "1.54")
    expect { receive_payment(inv, 100, "1.60") }.not_to change(TudlaAccounting::CarryingAmount, :count)
  end

  describe "the aging report's past view" do
    def owed(on) = TudlaAccounting::AgingReportGenerator.call(organization: organization, report_type: :receivable, as_of_date: on)[:totals][:total]

    it "settles foreign part payments at book value, as they stood on each date" do
      inv = invoice(100, "1.54")
      receive_payment(inv, 30, "1.60", on: Time.zone.local(2026, 4, 1))
      receive_payment(inv, 50, "1.50", on: Time.zone.local(2026, 4, 5))

      expect(owed(Date.new(2026, 3, 31))).to eq(aud(154))
      expect(owed(Date.new(2026, 4, 2))).to eq(aud("107.80"))
      expect(owed(Date.new(2026, 4, 30))).to eq(aud("30.80"))
      expect(owed(Date.new(2026, 4, 30))).to eq(carrying_amount(inv, "1100-EUR").amount)
    end

    it "does not count revaluations of the invoice as payments" do
      TudlaAccounting.configuration.unrealized_fx_gain_account_code = "4950"
      TudlaAccounting::ForexRate.create!(from: "EUR", to: "AUD", year: 2026, month: 3, day: 31, rate: BigDecimal("1.60"))
      invoice(100, "1.54")
      TudlaAccounting::RevaluationEntryGenerator.call(organization, Date.new(2026, 3, 31), Date.new(2026, 4, 1))

      expect(owed(Date.new(2026, 3, 15))).to eq(aud(154))
      expect(owed(Date.new(2026, 4, 30))).to eq(aud(154))
    end
  end

  context "without a realized gain account" do
    before { TudlaAccounting.configuration.realized_fx_gain_account_code = nil }

    it "still settles the carrying amount at book value, but cannot post the difference" do
      inv = invoice(100, "1.54")
      allow(Rails.logger).to receive(:warn)

      receive_payment(inv, 100, "1.60")

      expect(carrying_amount(inv, "1100-EUR").amount_cents).to eq(0)
      expect(balance("1100-EUR")).to eq(aud(-6))
      expect(Rails.logger).to have_received(:warn).with(/realized_fx_gain_account_code is not set; exchange difference on Invoice 1001 not posted/)
    end
  end
end
