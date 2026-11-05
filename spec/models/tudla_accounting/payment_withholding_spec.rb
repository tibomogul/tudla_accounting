require "rails_helper"

RSpec.describe TudlaAccounting::Payment, "tax a customer withheld" do
  let(:organization) { create(:organization, currency: "PHP") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:march) { year.children.order(:from_date).to_a[2] }
  let(:customer) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", tax_number: "444-555-666-000") }
  let(:vat) { TudlaAccounting::TaxCode.create!(organization: organization, code: "VAT12", name: "Output VAT", rate: "0.12", kind: :sales, account: account("2200")) }
  let(:code) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC160", name: "Services", rate: "0.02", payable_account: account("2300"), creditable_account: account("1200")) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "1020", name: "USD account", category: "asset", currency: "USD" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "1200", name: "Creditable tax", category: "asset" }, { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2200", name: "Output VAT", category: "liability" },
      { code: "2300", name: "Withholding payable", category: "liability" }, { code: "4000", name: "Sales", category: "income" }
    ], organization)
    TudlaAccounting.configuration.cash_account_codes = %w[1010]
  end

  after { TudlaAccounting.configuration.cash_account_codes = [] }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def php(amount) = Money.from_amount(BigDecimal(amount.to_s), "PHP")
  def postings(entry) = entry.details.map { |detail| [ detail.account.code, detail.tally, detail.amount_cents ] }
  def rows = TudlaAccounting::WithheldTax.where(organization: organization).order(:id)

  def invoice(**attributes)
    TudlaAccounting::Document.create!({ organization: organization, kind: "sales_invoice", contact: customer, issued_on: Date.new(2026, 3, 10),
                                        lines_attributes: [ { description: "Consulting", unit_price_cents: 10_000_00, account: account("4000"), tax_code: vat } ] }.merge(attributes)).approve!
  end

  def receive(amount_cents: 11_000_00, withholdings: [ { code: code, withheld_cents: 200_00 } ], applications: [], **attributes)
    described_class.record!(organization: organization, kind: "received", contact: customer, account: account("1010"), paid_on: Date.new(2026, 3, 20), amount_cents: amount_cents,
                            withholdings: withholdings, applications: applications, **attributes)
  end

  it "credits the receivable with the cash and the tax, settling the invoice, and keeps a row" do
    sold = invoice
    payment = receive(applications: [ { document: sold, amount_cents: 11_200_00 } ])
    expect(postings(payment.entry)).to contain_exactly([ "1010", "debit", 11_000_00 ], [ "1200", "debit", 200_00 ], [ "1100-PHP", "credit", 11_200_00 ])
    expect(payment).to have_attributes(amount: php(11_000), withheld: php(200), settled: php(11_200), unapplied: php(0))
    expect(sold.reload).to have_attributes(payment_status: "paid", amount_due: php(0))
    expect(rows.sole).to have_attributes(contact: customer, withholding_code: code, entry: payment.entry, payment: payment, direction: "by_customer", on: Date.new(2026, 3, 20),
                                         base_cents: 10_000_00, withheld_cents: 200_00, reversal: false, certificate_received_on: nil)
    expect(payment.bank_detail.amount_cents).to eq(11_000_00)
  end

  it "keeps the income given, and takes more than one code" do
    rent = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC100", name: "Rent", rate: "0.05", creditable_account: account("1200"))
    payment = receive(amount_cents: 1_000_00, withholdings: [ { code: code, withheld_cents: 21_00, base_cents: 1_000_00 }, { code: rent, withheld_cents: 50_00 } ])
    expect(rows.map { |row| [ row.withholding_code.code, row.base_cents, row.withheld_cents ] }).to eq([ [ "WC160", 1_000_00, 21_00 ], [ "WC100", 1_000_00, 50_00 ] ])
    expect(payment.withheld_cents).to eq(71_00)
    expect(postings(payment.entry)).to contain_exactly([ "1010", "debit", 1_000_00 ], [ "1200", "debit", 21_00 ], [ "1200", "debit", 50_00 ], [ "1100-PHP", "credit", 1_071_00 ])
  end

  it "applies no more than the cash and the tax together" do
    first, second = invoice, invoice
    expect { receive(applications: [ { document: first, amount_cents: 11_200_00 }, { document: second, amount_cents: 1 } ]) }
      .to raise_error(ArgumentError, /The payment and the tax withheld come to ₱11,200.00 but ₱11,200.01 is applied/)
    expect { described_class.record!(organization: organization, kind: "received", contact: customer, account: account("1010"), paid_on: Date.new(2026, 3, 20), amount_cents: 1_00,
                                     applications: [ { document: first, amount_cents: 2_00 } ]) }
      .to raise_error(ArgumentError, /The payment is ₱1.00 but ₱2.00 is applied/)
    expect(rows).to be_empty
  end

  it "refunds only cash: the tax stays as a credit to apply" do
    payment = receive
    expect(described_class.credit_left_cents(payment)).to eq(11_000_00)
    refund = ->(cents) { described_class.record!(organization: organization, kind: "refund", contact: customer, account: account("1010"), paid_on: Date.new(2026, 3, 21), amount_cents: cents, refund_of: payment) }
    expect { refund.call(11_000_01) }.to raise_error(ArgumentError, /Only ₱11,000.00 of .* is left to refund/)
    refund.call(11_000_00)
    expect(payment.reload.unapplied).to eq(php(200))
    expect(described_class.credit_left_cents(payment)).to eq(0)
    expect { refund.call(1) }.to raise_error(ArgumentError, /Only ₱0.00/)

    sold = invoice
    TudlaAccounting::Allocator.allocate!(payment.credit, sold.entry, amount_cents: 200_00, at: Time.zone.local(2026, 3, 22))
    expect(payment.reload.unapplied).to eq(php(0))
    expect(described_class.credit_left_cents(payment)).to eq(0)
  end

  it "keeps the tax back from what can be refunded once part of a payment is applied" do
    sold = invoice(lines_attributes: [ { description: "Consulting", unit_price_cents: 5_000_00, account: account("4000") } ])
    payment = receive(applications: [ { document: sold, amount_cents: 5_000_00 } ])
    expect(payment.unapplied).to eq(php(6_200))
    expect(described_class.credit_left_cents(payment)).to eq(6_000_00)
  end

  it "adds an opposite row when voided, and needs the certificate unmarked first, whichever way it is reversed" do
    payment = receive
    row = rows.sole
    row.mark_certificate!(on: Date.new(2026, 4, 5))
    expect { payment.void!(on: Date.new(2026, 4, 6), reason: "Bounced") }.to raise_error(ArgumentError, /certificate for it is marked received; unmark it first/)
    expect { payment.entry.reverse!(on: Date.new(2026, 4, 6)) }.to raise_error(ArgumentError, /unmark it first/)
    expect(payment.reload).not_to be_void

    row.unmark_certificate!
    payment.void!(on: Date.new(2026, 4, 6), reason: "Bounced")
    expect(rows.map { |each| [ each.on, each.base_cents, each.withheld_cents, each.reversal, each.payment_id ] })
      .to eq([ [ Date.new(2026, 3, 20), 10_000_00, 200_00, false, payment.id ], [ Date.new(2026, 4, 6), -10_000_00, -200_00, true, payment.id ] ])
    expect(TudlaAccounting::WithheldTax.certificate_waiting.where(organization: organization)).to be_empty
    expect { row.reload.mark_certificate!(on: Date.new(2026, 4, 7)) }.to raise_error(ArgumentError, "This amount has been reversed")
  end

  it "converts a foreign payment's tax, keeping the receivable's foreign amount at both" do
    sold = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: customer, issued_on: Date.new(2026, 3, 10), currency: "USD", exchange_rate: "60",
                                             lines_attributes: [ { description: "Licence", unit_price_cents: 100_00, account: account("4000") } ]).approve!
    payment = described_class.record!(organization: organization, kind: "received", contact: customer, account: account("1020"), paid_on: Date.new(2026, 3, 20), exchange_rate: "60", amount_cents: 98_00,
                                      withholdings: [ { code: code, withheld_cents: 2_00 } ], applications: [ { document: sold, amount_cents: 100_00 } ])
    expect(postings(payment.entry)).to contain_exactly([ "1020", "debit", 5_880_00 ], [ "1200", "debit", 120_00 ], [ "1100-USD", "credit", 6_000_00 ])
    expect(payment.entry.details.find { |detail| detail.account.code == "1100-USD" }.foreign_exchange.other_currency_cents).to eq(100_00)
    expect(payment.entry.details.find { |detail| detail.account.code == "1020" }.foreign_exchange.other_currency_cents).to eq(98_00)
    expect(payment.unapplied.cents).to eq(0)
    expect(sold.reload.payment_status).to eq("paid")
    expect(rows.sole).to have_attributes(base_cents: 6_000_00, withheld_cents: 120_00)
  end

  it "balances the cash receipts journal, and leaves the VAT report right on either basis" do
    sold = invoice
    receive(amount_cents: 5_500_00, withholdings: [ { code: code, withheld_cents: 100_00, base_cents: 5_000_00 } ], applications: [ { document: sold, amount_cents: 5_600_00 } ])
    books = TudlaAccounting::Reports::BooksOfAccounts.new(organization, from: march, thru: march)
    page = books.book("cash_receipts").pages.sole
    expect(page.balanced).to be(true)
    expect(books.book("general_ledger").pages.find { |ledger| ledger.account.code == "1200" }.totals).to include(debit: php(100), credit: php(0))
    expect(page.rows.first.cells).to include(cash: php(5_500), receivable: php(5_600), account_title: "Creditable tax", other: php(-100))
    from, thru = Time.zone.local(2026, 3, 1), Time.zone.local(2026, 3, 31).end_of_day
    expect(TudlaAccounting::TaxReport.call(organization, from: from, thru: thru, basis: :accrual)[:sales]).to eq(base: php(10_000), tax: php(1_200))
    expect(TudlaAccounting::TaxReport.call(organization, from: from, thru: thru, basis: :cash)[:sales]).to eq(base: php(5_000), tax: php(600))
  end

  it "says what is wrong with what was withheld, recording nothing" do
    message = lambda do |**attributes|
      receive(**attributes)
    rescue ArgumentError => e
      e.message
    end
    other = create(:organization, currency: "PHP")
    TudlaAccounting::AccountsCreator.call([ { code: "1200", name: "Theirs", category: "asset" } ], other)
    theirs = TudlaAccounting::WithholdingCode.create!(organization: other, code: "WC010", name: "Theirs", rate: "0.1", creditable_account: TudlaAccounting::Account.find_by!(organization: other))
    payable_only = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WI100", name: "Rent", rate: "0.05", payable_account: account("2300"))
    inactive = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "OLD", name: "Old", rate: "0.01", creditable_account: account("1200"), active: false)

    expect(message.call(withholdings: [ { code: nil, withheld_cents: 1_00 } ])).to include("Choose a withholding code")
    expect(message.call(withholdings: [ { code: theirs, withheld_cents: 1_00 } ])).to include("WC010 isn't a withholding code of this organization's")
    expect(message.call(withholdings: [ { code: payable_only, withheld_cents: 1_00 } ])).to include("WI100 has no account for tax withheld from you")
    expect(message.call(withholdings: [ { code: inactive, withheld_cents: 1_00 } ])).to include("OLD is inactive")
    expect(message.call(withholdings: [ { code: code, withheld_cents: 0 } ])).to include("must be more than zero")
    expect(message.call(withholdings: [ { code: code, withheld_cents: 1_00, base_cents: 0 } ])).to include("Give the income WC160 was withheld from")
    expect(message.call(withholdings: [ { code: code, withheld_cents: 10_00, base_cents: 1_00 } ])).to include("is more than the income")
    expect { described_class.record!(organization: organization, kind: "paid", contact: customer, account: account("1010"), paid_on: Date.new(2026, 3, 20), amount_cents: 1_00, withholdings: [ { code: code, withheld_cents: 1 } ]) }
      .to raise_error(ArgumentError, /WC160 is withheld when the bill is approved, not on the payment/)
    expect(rows).to be_empty
    expect(described_class.where(organization: organization)).to be_empty
  end

  describe "certificates" do
    it "marks and unmarks one, auditing each, and changes nothing else" do
      payment = receive
      row = rows.sole
      expect(TudlaAccounting::WithheldTax.certificate_waiting.where(organization: organization)).to eq([ row ])
      row.mark_certificate!(on: Date.new(2026, 4, 5))
      expect(row.reload).to be_certificate_received
      expect(TudlaAccounting::WithheldTax.certificate_received.where(organization: organization)).to eq([ row ])
      expect(TudlaAccounting::WithheldTax.certificate_waiting.where(organization: organization)).to be_empty
      expect { row.mark_certificate!(on: Date.new(2026, 4, 6)) }.to raise_error(ArgumentError, /marked received already/)

      row.unmark_certificate!
      expect(row.reload.certificate_received_on).to be_nil
      expect { row.unmark_certificate! }.to raise_error(ArgumentError, /isn't marked received/)
      expect { row.mark_certificate!(on: nil) }.to raise_error(ArgumentError, /Give the day/)

      events = TudlaAccounting::AuditEvent.where(organization: organization, subject: payment).where("action LIKE 'withheld_tax.%'").order(:id)
      expect(events.map { |event| [ event.action, event.details ] }).to eq([
        [ "withheld_tax.certificate_received", { "code" => "WC160", "withheld_cents" => 200_00, "on" => "2026-04-05" } ],
        [ "withheld_tax.certificate_unmarked", { "code" => "WC160", "withheld_cents" => 200_00 } ]
      ])

      expect { row.update!(withheld_cents: 1) }.to raise_error(ActiveRecord::RecordInvalid, /can't be changed/)
      expect(row.reload.destroy).to be(false)
    end

    it "marks several together, or none" do
      receive
      receive
      first, second = rows.to_a
      TudlaAccounting::WithheldTax.mark_certificates!([ first, second ], on: Date.new(2026, 4, 5))
      expect(rows.map(&:certificate_received_on)).to all(eq(Date.new(2026, 4, 5)))

      second.unmark_certificate!
      expect { TudlaAccounting::WithheldTax.mark_certificates!([ second.reload, first.reload ], on: Date.new(2026, 4, 9)) }.to raise_error(ArgumentError)
      expect(second.reload.certificate_received_on).to be_nil
    end

    it "has none for tax withheld from a supplier" do
      bill = TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: customer, issued_on: Date.new(2026, 3, 10),
                                               lines_attributes: [ { description: "Repair", unit_price_cents: 1_000_00, account: account("4000"), withholding_code: code } ]).approve!
      row = TudlaAccounting::WithheldTax.find_by!(entry: bill.entry)
      expect { row.mark_certificate!(on: Date.new(2026, 4, 5)) }.to raise_error(ArgumentError, /Only tax a customer withheld/)
    end
  end
end
