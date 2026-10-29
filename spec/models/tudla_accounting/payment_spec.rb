require "rails_helper"

RSpec.describe TudlaAccounting::Payment do
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both") }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1050", name: "Euro account", category: "asset", currency: "EUR" },
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "4000", name: "Sales", category: "income" },
      { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")

  def document(kind = "sales_invoice", cents = 100_00, contact: northwind)
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: contact, issued_on: Date.new(2026, 3, 1),
                                      lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account(kind == "bill" ? "6000" : "4000") } ]).approve!
  end

  def record(**attrs)
    described_class.record!(**{ organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 3, 20), amount_cents: 150_00 }.merge(attrs))
  end

  def postings(entry) = entry.details.map { |detail| [ detail.account.code, detail.tally, detail.amount_cents ] }

  it "posts money received against receivables, applies it as told, and keeps the rest as a credit" do
    first = document
    second = document("sales_invoice", 80_00)
    payment = record(reference: "EFT 991", applications: [ { document: first, amount_cents: 100_00 }, { document: second, amount_cents: 30_00 } ])

    expect(payment).to have_attributes(status: "posted", kind_label: "Payment received", title: "Payment from Northwind", amount: aud(150))
    expect(payment.entry).to have_attributes(posted?: true, source: payment, reference: "EFT 991", particulars: "Payment from Northwind (INV-0001, INV-0002)")
    expect(payment.entry.transacted_at).to eq(Time.zone.local(2026, 3, 20))
    expect(postings(payment.entry)).to contain_exactly([ "1000", "debit", 150_00 ], [ "1100-AUD", "credit", 150_00 ])
    expect(payment.credit).to have_attributes(related_party: northwind, carrying_amount_type: "receivable")
    expect([ first.reload.payment_status, second.reload.amount_due ]).to eq([ "paid", aud(50) ])
    expect(payment.reload.unapplied).to eq(aud(20))
    expect(payment.applications.map { |doc, amount, _| [ doc.number_label, amount ] }).to eq([ [ "INV-0001", aud(100) ], [ "INV-0002", aud(30) ] ])
    expect(TudlaAccounting::AuditEvent.find_by!(action: "payment.recorded").details).to eq("amount_cents" => 150_00, "documents" => %w[INV-0001 INV-0002])
  end

  it "posts money paid against payables, and leaves an unapplied payment as a credit" do
    supplier = TudlaAccounting::Contact.create!(organization: organization, name: "Acme", kind: "supplier")
    bill = document("bill", 40_00, contact: supplier)
    payment = record(kind: "paid", contact: supplier, amount_cents: 40_00, applications: [ { document: bill, amount_cents: 40_00 } ])
    expect(payment.title).to eq("Payment to Acme")
    expect(postings(payment.entry)).to contain_exactly([ "2100-AUD", "debit", 40_00 ], [ "1000", "credit", 40_00 ])
    expect(bill.reload.payment_status).to eq("paid")

    loose = record(kind: "paid", contact: supplier, amount_cents: 10_00)
    expect(loose.entry.particulars).to eq("Payment to Acme")
    expect(loose.unapplied).to eq(aud(10))
    expect(loose.applications).to eq([])
  end

  it "refuses what it can't record, recording nothing" do
    invoice = document
    supplier = TudlaAccounting::Contact.create!(organization: organization, name: "Acme", kind: "supplier")
    second = document
    expect { record(applications: [ { document: invoice, amount_cents: 100_00 }, { document: second, amount_cents: 60_00 } ]) }.to raise_error(ArgumentError, "The payment is $150.00 but $160.00 is applied")
    expect { record(amount_cents: 500_00, applications: [ { document: invoice, amount_cents: 160_00 } ]) }.to raise_error(ArgumentError, "$160.00 is more than is owed on INV-0001")
    expect { record(applications: [ { document: invoice, amount_cents: -5 } ]) }.to raise_error(ArgumentError, "Apply a positive amount to INV-0001")
    expect { record(kind: "paid", contact: northwind, applications: [ { document: invoice, amount_cents: 10_00 } ]) }
      .to raise_error(ArgumentError, "Invoice INV-0001 isn't an approved bill of Northwind's")
    expect { record(kind: "paid", contact: TudlaAccounting::Contact.create!(organization: organization, name: "Customer only")) }.to raise_error(ArgumentError, "Contact must be a supplier")
    expect { record(contact: supplier) }.to raise_error(ArgumentError, "Contact must be a customer")
    expect { record(account: account("1100")) }.to raise_error(ArgumentError, "Account must be a bank or cash account")
    expect { record(account: account("4000")) }.to raise_error(ArgumentError, "Account must be a bank or cash account")
    expect { record(account: account("1050")) }.to raise_error(ArgumentError, "Exchange rate is needed: no EUR rate was found for 20 Mar 2026")
    expect { record(amount_cents: 0, kind: "gift", paid_on: nil) }.to raise_error(ArgumentError, /Kind is not included in the list.*Paid on can't be blank.*Amount cents must be more than zero/)
    account("1000").update!(active: false)
    expect { record }.to raise_error(ArgumentError, "Account is inactive")
    account("1000").update!(active: true)
    year.children.order(:from_date).first(3).each(&:close!)
    expect { record }.to raise_error(ArgumentError)

    other = create(:organization, currency: "AUD")
    TudlaAccounting::AccountsCreator.call([ { code: "1000", name: "Theirs", category: "asset" } ], other)
    expect { record(contact: TudlaAccounting::Contact.create!(organization: other, name: "Stranger"), account: TudlaAccounting::Account.find_by!(organization: other, code: "1000")) }
      .to raise_error(ArgumentError, "Contact must belong to the same organization and Account must belong to the same organization")
    expect(described_class.count).to eq(0)
    expect(TudlaAccounting::Entry.where(source_type: described_class.name)).to be_empty
  end

  it "matches the bank statement line it was recorded from" do
    line = TudlaAccounting::BankStatementLine.create!(organization: organization, account: account("1000"), occurred_on: Date.new(2026, 3, 20), description: "NORTHWIND", amount_cents: 150_00,
                                                      currency: "AUD", external_id: "n1")
    payment = record(bank_line: line, applications: [ { document: document, amount_cents: 100_00 } ])
    expect(line.reload).to be_matched
    expect(line.details).to eq([ payment.bank_detail ])
    expect { payment.void!(on: Date.new(2026, 3, 31), reason: "Wrong") }.to raise_error(ArgumentError, "It is matched to a bank statement line; unmatch it on the banking page first")
  end

  it "voids by reversing its entry, taking it off what it paid, and so does reversing the entry" do
    invoice = document
    payment = record(amount_cents: 100_00, applications: [ { document: invoice, amount_cents: 100_00 } ])
    expect { payment.void!(on: Date.new(2026, 3, 31), reason: "") }.to raise_error(ArgumentError, "Give a reason for voiding it")
    payment.void!(on: Date.new(2026, 3, 31), reason: "Bounced")
    expect(payment.reload).to have_attributes(status: "void", voided_on: Date.new(2026, 3, 31), void_reason: "Bounced", unapplied: aud(0))
    expect(invoice.reload).to have_attributes(payment_status: "unpaid", amount_due: aud(100))
    expect { payment.void!(on: Date.new(2026, 3, 31), reason: "again") }.to raise_error(ArgumentError, "This payment is void already")

    other = record(amount_cents: 100_00, applications: [ { document: invoice, amount_cents: 100_00 } ])
    other.entry.reverse!(on: Date.new(2026, 4, 1))
    expect(other.reload).to have_attributes(status: "void", voided_on: Date.new(2026, 4, 1))
    expect(invoice.reload.amount_due).to eq(aud(100))
    expect(TudlaAccounting::AuditEvent.where(action: "payment.voided").sole.details).to eq("on" => "2026-03-31", "reason" => "Bounced")
  end

  it "doesn't change or go away once recorded" do
    payment = record
    expect(payment.update(amount_cents: 1)).to be(false)
    expect(payment.errors[:base]).to eq([ "A recorded payment can't be changed; void it and record another" ])
    expect(payment.reload.destroy).to be(false)
    expect(described_class.count).to eq(1)
  end
end
