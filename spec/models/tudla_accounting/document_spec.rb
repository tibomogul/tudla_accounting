require "rails_helper"

RSpec.describe TudlaAccounting::Document do
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST on sales", rate: "0.1", kind: :sales, account: account("2200")) }
  let(:gstp) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GSTP", name: "GST on purchases", rate: "0.1", kind: :purchases, account: account("2200")) }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", payment_terms_days: 30) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }, { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")

  def document(kind = "sales_invoice", lines: nil, **attrs)
    lines ||= [ { description: "Consulting", quantity: "2.5", unit_price_cents: 120_00, account: account(kind.in?(%w[bill supplier_credit]) ? "6000" : "4000"),
                  tax_code: kind.in?(%w[bill supplier_credit]) ? gstp : gst } ]
    described_class.create!({ organization: organization, kind: kind, contact: northwind, issued_on: Date.new(2026, 3, 10), lines_attributes: lines }.merge(attrs))
  end

  def postings(entry) = entry.details.map { |detail| [ detail.account.code, detail.tally, detail.amount_cents, detail.tax_role ] }

  it "works out each line and the totals, with tax added or included" do
    invoice = document(lines: [ { description: "  Consulting   hours ", quantity: "2.5", unit_price_cents: 120_00, account: account("4000"), tax_code: gst },
                                { description: "Travel", quantity: "1", unit_price_cents: 33_33, account: account("4000") } ])
    expect(invoice.lines.map { |line| [ line.description, line.amount_cents, line.tax_cents, line.net_cents ] }).to eq([ [ "Consulting hours", 300_00, 30_00, 300_00 ], [ "Travel", 33_33, 0, 33_33 ] ])
    expect(invoice).to have_attributes(subtotal: aud("333.33"), tax: aud(30), total: aud("363.33"), title: "Draft invoice", payment_status: "draft", amount_due: aud(0))

    inclusive = document(tax_inclusive: true)
    expect(inclusive).to have_attributes(subtotal: aud("272.73"), tax: aud("27.27"), total: aud(300))
  end

  it "approves an invoice: numbers it and posts its entry, opening a receivable for the contact due on its due date" do
    invoice = document(due_on: Date.new(2026, 4, 9), reference: "PO 77")
    invoice.approve!
    expect(invoice.reload).to have_attributes(status: "approved", number: 1, number_label: "INV-0001", title: "Invoice INV-0001", payment_status: "unpaid", amount_due: aud(330))

    entry = invoice.entry
    expect(entry).to have_attributes(posted?: true, source: invoice, reference: "INV-0001", particulars: "Invoice INV-0001 – Northwind")
    expect(entry.transacted_at).to eq(Time.zone.local(2026, 3, 10))
    expect(postings(entry)).to contain_exactly([ "1100", "debit", 330_00, nil ], [ "4000", "credit", 300_00, "base" ], [ "2200", "credit", 30_00, "tax" ])
    expect(entry.details.find { |detail| detail.account.code == "4000" }.description).to eq("Consulting")
    receivable = entry.details.filter_map(&:carrying_amount).sole
    expect(receivable).to have_attributes(carrying_amount_type: "receivable", amount_cents: 330_00, related_party: northwind)
    expect(receivable.due_date).to be_within(0.001).of(Time.zone.local(2026, 4, 9).end_of_day)

    expect(document.approve!.number_label).to eq("INV-0002")
    expect(TudlaAccounting::AuditEvent.where(organization: organization, action: "document.approved").count).to eq(2)
  end

  it "posts a bill to the payables account, numbered in its own run, with the supplier's number in the particulars" do
    bill = document("bill", reference: "S-4471", due_on: nil).approve!
    expect(bill).to have_attributes(number_label: "BILL-0001", total: aud(330))
    expect(bill.entry.particulars).to eq("Bill BILL-0001 – Northwind (their S-4471)")
    expect(postings(bill.entry)).to contain_exactly([ "2100", "credit", 330_00, nil ], [ "6000", "debit", 300_00, "base" ], [ "2200", "debit", 30_00, "tax" ])
    payable = bill.entry.details.filter_map(&:carrying_amount).sole
    expect(payable).to have_attributes(carrying_amount_type: "payable", due_date: nil, related_party: northwind)
  end

  it "applies a credit note to the invoice it credits, and leaves the rest as a credit to apply" do
    invoice = document.approve!
    credit = document("sales_credit", credited_document: invoice, lines: [ { description: "Refund of an hour", quantity: 1, unit_price_cents: 120_00, account: account("4000"), tax_code: gst } ]).approve!
    expect(credit).to have_attributes(number_label: "CN-0001", payment_status: "paid", amount_due: aud(0))
    expect(postings(credit.entry)).to contain_exactly([ "1100", "credit", 132_00, nil ], [ "4000", "debit", 120_00, "base" ], [ "2200", "debit", 12_00, "tax" ])
    expect(invoice.reload).to have_attributes(payment_status: "part_paid", amount_due: aud(198))

    big = document("sales_credit", credited_document: invoice, lines: [ { description: "Everything", quantity: 1, unit_price_cents: 200_00, account: account("4000"), tax_code: gst } ]).approve!
    expect(invoice.reload).to have_attributes(payment_status: "paid", amount_due: aud(0))
    expect(big).to have_attributes(payment_status: "part_paid", amount_due: aud(22))
    expect(described_class.with_open_cents.find(big.id).amount_due).to eq(aud(22))

    supplier_credit = document("supplier_credit").approve!
    expect(postings(supplier_credit.entry)).to include([ "2100", "debit", 330_00, nil ])
    expect(supplier_credit.payment_status).to eq("unpaid")
  end

  it "checks the contact, dates, lines and what a credit note credits" do
    supplier = TudlaAccounting::Contact.create!(organization: organization, name: "Acme", kind: "supplier")
    gone = TudlaAccounting::Contact.create!(organization: organization, name: "Gone", active: false)
    bad = described_class.new(organization: organization, kind: "sales_invoice", contact: supplier, issued_on: Date.new(2026, 3, 10), due_on: Date.new(2026, 3, 1))
    expect(bad).not_to be_valid
    expect(bad.errors.full_messages).to contain_exactly("Contact must be a customer", "Due on must be on or after the date", "Add at least one line")
    expect(described_class.new(organization: organization, kind: "bill", contact: northwind.tap { |contact| contact.kind = "customer" }).tap(&:valid?).errors[:contact]).to eq([ "must be a supplier" ])
    northwind.reload
    expect(described_class.new(organization: organization, kind: "sales_invoice", contact: gone).tap(&:valid?).errors[:contact]).to eq([ "is inactive" ])
    expect(described_class.new(kind: "quote", status: "maybe").tap(&:valid?).errors.attribute_names).to include(:kind, :status, :issued_on)

    line = { description: "", quantity: "-1", unit_price_cents: -5, account: account("1100"), tax_code: gstp }
    expect { document(lines: [ line ]) }.to raise_error(ActiveRecord::RecordInvalid) { |error|
      expect(error.record.lines.first.errors.full_messages).to contain_exactly(
        "Description can't be blank", "Quantity must be greater than or equal to 0", "Unit price cents must be greater than or equal to 0",
        "Account can't be the receivables or payables account; the document posts its total there", "Tax code must be a sales code"
      )
    }

    other = create(:organization, currency: "AUD")
    TudlaAccounting::AccountsCreator.call([ { code: "4000", name: "Theirs", category: "income" }, { code: "2200", name: "GST", category: "liability" } ], other)
    theirs = TudlaAccounting::TaxCode.create!(organization: other, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: TudlaAccounting::Account.find_by!(organization: other, code: "2200"))
    stranger = TudlaAccounting::Contact.create!(organization: other, name: "Stranger")
    foreign = described_class.new(organization: organization, kind: "sales_invoice", contact: stranger, issued_on: Date.current,
                                  lines_attributes: [ { description: "x", unit_price_cents: 1, account: TudlaAccounting::Account.find_by!(organization: other, code: "4000"), tax_code: theirs } ])
    expect(foreign).not_to be_valid
    expect(foreign.errors[:contact]).to eq([ "must belong to the same organization" ])
    expect(foreign.lines.first.tap(&:valid?).errors.full_messages).to contain_exactly("Account must belong to the same organization", "Tax code must belong to the same organization")
    account("6000").update!(active: false)
    expect(described_class.new(organization: organization, kind: "bill", contact: northwind, issued_on: Date.current,
                               lines_attributes: [ { description: "x", unit_price_cents: 1, account: account("6000") } ]).lines.first.tap(&:valid?).errors[:account]).to eq([ "is inactive" ])

    draft_invoice = document
    credit = described_class.new(organization: organization, kind: "sales_credit", contact: northwind, issued_on: Date.current, credited_document: document,
                                 lines_attributes: [ { description: "x", unit_price_cents: 1, account: account("4000") } ])
    expect(credit).not_to be_valid
    expect(credit.errors[:credited_document]).to eq([ "must be an approved invoice" ])
    credit.credited_document = described_class.create!(organization: organization, kind: "sales_invoice", contact: TudlaAccounting::Contact.create!(organization: organization, name: "Globex"),
                                                       issued_on: Date.current, lines_attributes: [ { description: "x", unit_price_cents: 1, account: account("4000") } ]).approve!
    expect(credit.tap(&:valid?).errors[:credited_document]).to eq([ "must be to the same contact" ])
    invoice = described_class.new(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.current, credited_document: draft_invoice,
                                  lines_attributes: [ { description: "x", unit_price_cents: 1, account: account("4000") } ])
    expect(invoice.tap(&:valid?).errors[:credited_document]).to eq([ "can only be given for a credit note" ])
  end

  it "won't approve twice, nothing, for an inactive contact, or into a closed period, and leaves the draft as it was" do
    invoice = document.approve!
    expect { invoice.approve! }.to raise_error(ArgumentError, "Only a draft can be approved")

    free = document(lines: [ { description: "Free", quantity: 1, unit_price_cents: 0, account: account("4000") } ])
    expect { free.approve! }.to raise_error(ArgumentError, "The total must be more than zero")

    draft = document
    northwind.update!(active: false)
    expect { draft.reload.approve! }.to raise_error(ArgumentError, "Northwind is inactive")
    northwind.update!(active: true)

    northwind.update!(kind: "supplier")
    expect { draft.reload.approve! }.to raise_error(ArgumentError, "Contact must be a customer")
    expect(draft).to have_attributes(number: nil, number_label: nil, status: "draft")
    northwind.update!(kind: "both")

    year.children.order(:from_date).first(3).each(&:close!)
    expect { draft.reload.approve! }.to raise_error(ArgumentError)
    expect(draft.reload).to have_attributes(status: "draft", number: nil, entry: nil)
    expect(TudlaAccounting::Sequence.find_by(organization: organization, name: "document:sales_invoice").last_value).to eq(1)
  end

  it "numbers documents the way the setting says, keeping the numbers given" do
    original = TudlaAccounting.configuration.document_number_format
    TudlaAccounting.configuration.document_number_format = { sales_invoice: "%<number>05d" }
    expect(document.approve!.number_label).to eq("00001")
    expect(document("bill").approve!.number_label).to eq("BILL-0001")
    TudlaAccounting.configuration.document_number_format = ->(doc) { "#{doc.kind.upcase}/#{doc.number}" }
    expect(document.approve!.number_label).to eq("SALES_INVOICE/2")
    expect { TudlaAccounting.configuration.document_number_format = { quote: "Q%<number>d" } }.to raise_error(ArgumentError, /unknown document kind "quote"/)
  ensure
    TudlaAccounting.configuration.document_number_format = original
  end

  it "keeps an approved document as it is, and deletes only drafts" do
    invoice = document.approve!
    expect(invoice.update(reference: "changed")).to be(false)
    expect(invoice.errors[:base]).to eq([ "An approved document can't be changed; void it and issue another" ])
    invoice.reload.lines.load.first.description = "Other"
    expect(invoice.save).to be(false)
    line = invoice.reload.lines.first
    expect(line.update(quantity: 9)).to be(false)
    expect(line.errors[:base]).to eq([ "An approved document's lines can't be changed" ])
    expect(invoice.lines.build(description: "More", unit_price_cents: 1, account: account("4000")).save).to be(false)
    invoice = described_class.find(invoice.id)
    expect(invoice.destroy).to be(false)
    expect(invoice.errors[:base]).to eq([ "Only a draft can be deleted; void an approved document instead" ])

    draft = document
    draft.update!(reference: "PO 1", lines_attributes: [ { id: draft.lines.first.id, quantity: 3 } ])
    expect(draft.total).to eq(aud(396))
    draft.destroy!
    expect(TudlaAccounting::DocumentLine.where(document_id: draft.id)).to be_empty
    events = TudlaAccounting::AuditEvent.where(organization: organization, subject_type: described_class.name, subject_id: draft.id).order(:id)
    expect(events.map(&:action)).to eq(%w[document.created document.updated document.deleted])
    expect(events.second.details["changes"].keys).to include("reference", "subtotal_cents")
    expect(events.last.subject_label).to eq("an invoice for Northwind")
  end

  it "voids by reversing its entry, once nothing is applied to it, and so does reversing the entry" do
    invoice = document.approve!
    credit = document("sales_credit", credited_document: invoice).approve!
    expect { invoice.void!(on: Date.new(2026, 3, 31), reason: " ") }.to raise_error(ArgumentError, "Give a reason for voiding it")
    expect { invoice.void!(on: Date.new(2026, 3, 31), reason: "Wrong customer") }.to raise_error(ArgumentError, "Reverse the payments against it first")

    credit.void!(on: Date.new(2026, 3, 31), reason: "Issued twice")
    expect(credit.reload).to have_attributes(status: "void", voided_on: Date.new(2026, 3, 31), void_reason: "Issued twice", payment_status: "void", amount_due: aud(0))
    expect(invoice.reload.amount_due).to eq(aud(330))
    invoice.void!(on: Date.new(2026, 3, 31), reason: "Wrong customer")
    expect(invoice.reload.entry.reversal).to be_present
    expect { invoice.void!(on: Date.current, reason: "again") }.to raise_error(ArgumentError, "Only an approved document can be voided")

    bill = document("bill").approve!
    bill.entry.reverse!(on: Date.new(2026, 4, 1))
    expect(bill.reload).to have_attributes(status: "void", voided_on: Date.new(2026, 4, 1), void_reason: nil)
    expect(TudlaAccounting::AuditEvent.where(organization: organization, action: "document.voided").pluck(:details)).to eq([
      { "on" => "2026-03-31", "reason" => "Issued twice" }, { "on" => "2026-03-31", "reason" => "Wrong customer" }
    ])
  end

  it "keeps its contact, accounts and tax codes from being deleted" do
    document
    expect(northwind).not_to be_deletable
    expect(account("4000")).not_to be_deletable
    gst.destroy
    expect(gst.errors[:base]).to eq([ "Recurring entries, bank rules, tax returns, contacts or invoices and bills use GST; change them first" ])
  end
end
