require "rails_helper"
require_relative "../../support/entry_sources"

# Tax counted as money changes hands rather than as invoices and bills are posted.
RSpec.describe "Cash-basis tax", type: :service do
  include_context "with entry source models"

  let(:organization) { create(:organization, currency: "AUD") }
  let(:globex) { create(:organization, name: "Globex") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting.configuration.related_party_method = :customer
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" },
      { code: "1100", name: "Receivables", category: "asset", children: [
        { code: "1100-EUR", name: "Receivables EUR", category: "asset", currency: "EUR" } ] },
      { code: "2100", name: "Payables", category: "liability" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }, { code: "4100", name: "Returns", category: "income" },
      { code: "4950", name: "FX gains", category: "income" }, { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
    TudlaAccounting.configuration.realized_fx_gain_account_code = "4950"
    TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST on sales", rate: "0.1", kind: :sales, account: account("2200"))
    TudlaAccounting::TaxCode.create!(organization: organization, code: "GSTP", name: "GST on purchases", rate: "0.1", kind: :purchases, account: account("2200"))
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def on(month, day) = Time.zone.local(2026, month, day)

  def book(particulars, at, details, source: nil, related: nil, **options)
    entry = TudlaAccounting::Entry.create_from_ruby_hash({ organization_type: "Organization", organization_id: organization.id, particulars: particulars,
                                                          transacted_at: at.iso8601, details: details }.merge(options))
    entry.update!(source: source, related: related) if source || related
    entry.post(entry.transacted_at)
    entry
  end

  def invoice(at, net) = book("Invoice", at, [ { account_code: "1100", amount: "AUD #{net * 1.1}" }, { account_code: "4000", amount: "AUD #{net}", tax_code: "GST" } ],
                              source: Invoice.create!(customer: globex))
  def payment(at, amount, related: nil) = book("Payment", at, [ { account_code: "1000", amount: "AUD #{amount}" }, { account_code: "1100", amount: "AUD -#{amount}" } ],
                                               source: Payment.create!(customer: globex), related: related)

  def report(month, basis: :cash) = TudlaAccounting::TaxReport.call(organization, from: on(month, 1), thru: on(month, 1).end_of_month, basis: basis)
  def gst(month, basis: :cash) = report(month, basis: basis)[:codes].find { |row| row[:tax_code].code == "GST" }.values_at(:base, :tax)

  it "counts an invoice's tax as it is paid, not when it is posted" do
    inv = invoice(on(3, 1), 1_000)
    expect(gst(3, basis: :accrual)).to eq([ aud(1_000), aud(100) ])
    expect(gst(3)).to eq([ aud(0), aud(0) ])

    payment(on(4, 10), 550, related: inv) # half
    payment(on(5, 10), 550, related: inv) # the rest
    expect([ gst(4), gst(5) ]).to eq([ [ aud(500), aud(50) ], [ aud(500), aud(50) ] ])
  end

  it "counts a cash sale when it is posted" do
    book("Cash sale", on(3, 2), [ { account_code: "1000", amount: "AUD 220.00" }, { account_code: "4000", amount: "AUD 200.00", tax_code: "GST" } ])
    expect(gst(3)).to eq([ aud(200), aud(20) ])
  end

  it "takes the tax back in the month a payment is taken off, and ignores an unpaid invoice's reversal" do
    inv = invoice(on(3, 1), 1_000)
    pay = payment(on(3, 20), 1_100, related: inv)
    expect(gst(3)).to eq([ aud(1_000), aud(100) ])

    TudlaAccounting::Allocator.unallocate!(TudlaAccounting::Allocation.sole, at: on(4, 5))
    expect(gst(4)).to eq([ aud(-1_000), aud(-100) ])

    inv.reload.reverse!(on: Date.new(2026, 4, 6))
    expect(gst(4)).to eq([ aud(-1_000), aud(-100) ]) # the reversal itself doesn't count
    expect(pay.reload.reversal_blocker).to be_nil
  end

  it "nets the tax on the part of an invoice settled by a taxed credit note" do
    inv = invoice(on(3, 1), 1_000)
    book("Credit note", on(3, 5), [ { account_code: "4100", amount: "AUD -200.00", tax_code: "GST" }, { account_code: "1100", amount: "AUD -220.00" } ],
         source: CreditNote.create!(customer: globex), related: inv)
    expect(gst(3)).to eq([ aud(0), aud(0) ]) # 20% of the invoice settled, by a credit note for that 20%
    expect(gst(3, basis: :accrual)).to eq([ aud(800), aud(80) ])

    payment(on(4, 1), 880, related: inv)
    expect(gst(4)).to eq([ aud(800), aud(80) ])
  end

  it "counts a bill's tax on the purchases side as it is paid" do
    bill = book("Bill", on(3, 1), [ { account_code: "6000", amount: "AUD 330.00", tax_code: "GSTP" }, { account_code: "2100", amount: "AUD 330.00" } ],
                tax_inclusive: true, source: Bill.create!(customer: globex))
    book("Paid", on(4, 2), [ { account_code: "2100", amount: "AUD -330.00" }, { account_code: "1000", amount: "AUD -330.00" } ],
         source: Disbursement.create!(customer: globex), related: bill)
    expect(report(3)[:purchases]).to eq(base: aud(0), tax: aud(0))
    expect(report(4)[:purchases]).to eq(base: aud(300), tax: aud(30))
    expect(report(4)[:net_tax]).to eq(aud(-30))
  end

  it "shares a foreign invoice's tax by the foreign amount settled" do
    TudlaAccounting::AccountsCreator.call([ { code: "4200", name: "Sales EUR", category: "income", currency: "EUR" } ], organization)
    inv = book("Export", on(3, 1), [ { account_code: "1100-EUR", amount: "AUD 176.00", fx: { other_currency_amount: "EUR 110.00", fx_rate: "1.6" } },
                                     { account_code: "4000", amount: "AUD 160.00", tax_code: "GST" } ], source: Invoice.create!(customer: globex))
    book("Paid EUR", on(4, 1), [ { account_code: "1000", amount: "AUD 93.50" }, { account_code: "1100-EUR", amount: "AUD -93.50", fx: { other_currency_amount: "EUR -55.00", fx_rate: "1.7" } } ],
         source: Payment.create!(customer: globex), related: inv)
    expect(gst(4)).to eq([ aud(80), aud(8) ]) # half the euros, so half the tax, at the invoice's amounts
  end

  it "uses the tax_basis setting by default, and refuses another basis" do
    invoice(on(3, 1), 1_000)
    TudlaAccounting.configuration.tax_basis = :cash
    expect(TudlaAccounting::TaxReport.call(organization, from: on(3, 1), thru: on(3, 31).end_of_day)).to include(basis: :cash, net_tax: aud(0))
    expect { report(3, basis: :whenever) }.to raise_error(ArgumentError, "basis must be one of accrual, cash")
  end
end
