require "rails_helper"
require_relative "../../support/entry_sources"

# Reversing invoices, bills and their payments keeps receivables and payables right.
RSpec.describe "Reversing receivables and payables", type: :service do
  include_context "with entry source models"

  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting.configuration.realized_fx_gain_account_code = "4950"
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash", category: "asset" },
      { code: "1001", name: "Bank EUR", category: "asset", currency: "EUR" },
      { code: "1100", name: "Accounts Receivable", category: "asset", children: [
        { code: "1100-EUR", name: "Accounts Receivable - EUR", category: "asset", currency: "EUR" } ] },
      { code: "2100", name: "Accounts Payable", category: "liability" },
      { code: "4000", name: "Sales", category: "income" },
      { code: "4950", name: "Realized FX Gain", category: "income" },
      { code: "5000", name: "Purchases", category: "expense" }
    ], organization)
  end

  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def balance(code) = TudlaAccounting::Balance.peek(account(code), year).ending_amount
  def on(month, day) = Time.zone.local(2026, month, day)

  def post(lines, at:, particulars: "Entry", **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: particulars, transacted_at: at, **attrs)
    lines.each do |code, tally, amount, fx|
      line = entry.details.build(account: account(code), tally: tally, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
      line.build_foreign_exchange(other_currency: "EUR", other_currency_cents: (BigDecimal(fx[0].to_s) * 100).to_i, rate: BigDecimal(fx[1])) if fx
    end
    entry.save!
    entry.post(at)
    entry
  end

  def invoice(amount, at: on(3, 1)) = post([ [ "1100", :debit, amount ], [ "4000", :credit, amount ] ], at: at, particulars: "Invoice",
                                           source: Invoice.create!(due_date: at + 30.days))
  def receive(invoice, amount, at:) = post([ [ "1000", :debit, amount ], [ "1100", :credit, amount ] ], at: at, particulars: "Payment",
                                           source: Payment.create!, related: invoice)
  def carrying_amount(entry) = entry.details.filter_map(&:carrying_amount).first.reload
  def owed(as_of) = TudlaAccounting::AgingReportGenerator.call(organization: organization, report_type: :receivable, as_of_date: as_of)[:totals][:total]

  it "closes the receivable when an unpaid invoice is reversed" do
    inv = invoice(500)

    inv.reverse!(on: on(4, 1))

    expect(carrying_amount(inv).amount_cents).to eq(0)
    expect([ balance("1100"), balance("4000") ]).to eq([ aud(0), aud(0) ])
    expect(owed(Date.new(2026, 3, 31))).to eq(aud(500)) # before the reversal it was still owed
    expect(owed(Date.new(2026, 4, 1))).to eq(aud(0))
  end

  it "needs the payments reversed before the invoice, then restores what they settled" do
    inv = invoice(500)
    payment = receive(inv, 200, at: on(3, 10))

    expect(inv.reversal_blocker).to eq("Reverse the payments against it first")
    expect { inv.reverse!(on: on(4, 1)) }.to raise_error(ArgumentError, "Reverse the payments against it first")

    payment.reverse!(on: on(3, 20))
    expect(carrying_amount(inv).amount_cents).to eq(500_00)
    expect(balance("1000")).to eq(aud(0))
    expect(owed(Date.new(2026, 3, 15))).to eq(aud(300)) # the payment still counted then
    expect(owed(Date.new(2026, 3, 25))).to eq(aud(500))

    expect(inv.reload.reversal_blocker).to be_nil
    inv.reverse!(on: on(4, 1))
    expect(carrying_amount(inv).amount_cents).to eq(0)
  end

  it "recomputes what is owed when one of several part payments is reversed" do
    inv = invoice(500)
    receive(inv, 100, at: on(3, 5))
    middle = receive(inv, 150, at: on(3, 10))
    receive(inv, 50, at: on(3, 15))
    expect(carrying_amount(inv).amount_cents).to eq(200_00)

    middle.reverse!(on: on(3, 20))

    expect(carrying_amount(inv).amount_cents).to eq(350_00)
    expect(balance("1100")).to eq(aud(350))
  end

  it "reverses a foreign payment's realized gain and restores the foreign amount owed" do
    inv = post([ [ "1100-EUR", :debit, 154, [ 100, "1.54" ] ], [ "4000", :credit, 154 ] ], at: on(3, 1), particulars: "Invoice EUR",
               source: Invoice.create!(due_date: on(4, 1)))
    payment = post([ [ "1000", :debit, 96 ], [ "1100-EUR", :credit, 96, [ 60, "1.60" ] ] ], at: on(3, 10), particulars: "Payment EUR",
                   source: Payment.create!, related: inv)
    expect(balance("4950")).to eq(aud("3.60")) # 60 x (1.60 - 1.54)
    expect(carrying_amount(inv)).to have_attributes(amount_cents: 61_60)

    payment.reverse!(on: on(3, 20))

    realized = TudlaAccounting::Entry.find_by(related: payment, particulars: "Realized exchange gain on Invoice EUR")
    expect(realized.reversal).to be_present
    expect(balance("4950")).to eq(aud(0))
    expect(balance("1100-EUR")).to eq(aud(154))
    expect(carrying_amount(inv).amount_cents).to eq(154_00)
    expect(carrying_amount(inv).forex.other_currency_amount_cents).to eq(100_00)
  end

  it "won't reverse a realized exchange difference on its own" do
    inv = post([ [ "1100-EUR", :debit, 154, [ 100, "1.54" ] ], [ "4000", :credit, 154 ] ], at: on(3, 1), source: Invoice.create!(due_date: on(4, 1)))
    payment = post([ [ "1000", :debit, 160 ], [ "1100-EUR", :credit, 160, [ 100, "1.60" ] ] ], at: on(3, 10), source: Payment.create!, related: inv)
    realized = TudlaAccounting::Entry.find_by(related: payment)

    expect(realized.reversal_blocker).to eq("Reverse the payment this exchange difference came from instead")
  end

  it "undoes a foreign payment's change to a foreign-currency bank balance" do
    bank = create(:tudla_accounting_bank_account_balance, account: account("1001"), currency: "EUR", balance_cents: 1_000_00)
    inv = post([ [ "1100-EUR", :debit, 154, [ 100, "1.54" ] ], [ "4000", :credit, 154 ] ], at: on(3, 1), source: Invoice.create!(due_date: on(4, 1)))
    payment = post([ [ "1001", :debit, 154 ], [ "1100-EUR", :credit, 154, [ 100, "1.54" ] ] ], at: on(3, 10), source: Payment.create!, related: inv)
    expect(bank.reload.balance_cents).to eq(1_100_00)

    payment.reverse!(on: on(3, 20))

    expect(bank.reload.balance_cents).to eq(1_000_00)
  end

  it "works the same way for bills and disbursements" do
    bill = post([ [ "5000", :debit, 300 ], [ "2100", :credit, 300 ] ], at: on(3, 1), particulars: "Bill", source: Bill.create!(due_date: on(4, 1)))
    disbursement = post([ [ "2100", :debit, 300 ], [ "1000", :credit, 300 ] ], at: on(3, 10), source: Disbursement.create!, related: bill)
    expect(carrying_amount(bill).amount_cents).to eq(0)

    expect(bill.reversal_blocker).to eq("Reverse the payments against it first")
    disbursement.reverse!(on: on(3, 20))
    expect(carrying_amount(bill).amount_cents).to eq(300_00)

    bill.reverse!(on: on(3, 21))
    expect(carrying_amount(bill).amount_cents).to eq(0)
    expect([ balance("2100"), balance("5000") ]).to eq([ aud(0), aud(0) ])
  end

  it "doesn't open a new receivable or settle anything with the reversal entries themselves" do
    inv = invoice(500)
    payment = receive(inv, 200, at: on(3, 10))
    expect { payment.reverse!(on: on(3, 20)) }.not_to change(TudlaAccounting::CarryingAmount, :count)
    expect { inv.reverse!(on: on(3, 21)) }.not_to change(TudlaAccounting::CarryingAmount, :count)
  end
end
