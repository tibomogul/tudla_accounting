require "rails_helper"

RSpec.describe TudlaAccounting::Document, "withholding from suppliers" do
  let(:organization) { create(:organization, currency: "PHP") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:supplier) { TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier", tax_number: "444-555-666-000") }
  let(:input_vat) { TudlaAccounting::TaxCode.create!(organization: organization, code: "IN12", name: "Input VAT", rate: "0.12", kind: :purchases, account: account("1300")) }
  let(:code) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Contractors", rate: "0.02", payable_account: account("2300"), creditable_account: account("1200")) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "1020", name: "USD account", category: "asset", currency: "USD" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "1200", name: "Creditable tax", category: "asset" }, { code: "1300", name: "Input VAT", category: "asset" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "2300", name: "Withholding payable", category: "liability" }, { code: "6000", name: "Repairs", category: "expense" }, { code: "4000", name: "Sales", category: "income" }
    ], organization)
    TudlaAccounting.configuration.cash_account_codes = %w[1010]
  end

  after { TudlaAccounting.configuration.cash_account_codes = [] }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def php(amount) = Money.from_amount(BigDecimal(amount.to_s), "PHP")
  def postings(entry) = entry.details.map { |detail| [ detail.account.code, detail.tally, detail.amount_cents ] }
  def rows = TudlaAccounting::WithheldTax.where(organization: organization).order(:id)

  def bill(kind: "bill", cents: 10_000_00, withholding: code, tax: input_vat, **attributes)
    described_class.create!({ organization: organization, kind: kind, contact: supplier, issued_on: Date.new(2026, 3, 10),
                              lines_attributes: [ { description: "Aircon repair", unit_price_cents: cents, account: account("6000"), tax_code: tax, withholding_code: withholding } ] }.merge(attributes))
  end

  it "keeps the total as charged, and makes what is owed the total less the tax withheld" do
    draft = bill
    expect(draft).to have_attributes(subtotal: php(10_000), tax: php(1_200), total: php(11_200), withheld: php(200), payable: php(11_000))
    expect(draft.lines.sole.withheld_cents).to eq(200_00)
    expect(rows).to be_empty
  end

  it "withholds on the amount before tax when the prices include it, rounding each line the configured way" do
    inclusive = bill(cents: 11_200_00, tax_inclusive: true)
    expect(inclusive).to have_attributes(subtotal: php(10_000), total: php(11_200), withheld: php(200))
    expect(bill(cents: 12_50, tax: nil).withheld_cents).to eq(25)
  end

  it "posts the tax on the same side as the payable, and keeps a row for each line" do
    approved = bill.approve!
    expect(postings(approved.entry)).to contain_exactly([ "2100-PHP", "credit", 11_000_00 ], [ "6000", "debit", 10_000_00 ], [ "1300", "debit", 1_200_00 ], [ "2300", "credit", 200_00 ])
    expect(approved).to have_attributes(payment_status: "unpaid", amount_due: php(11_000), total_in_base: php(11_000))
    expect(rows.sole).to have_attributes(contact: supplier, withholding_code: code, entry: approved.entry, document_line: approved.lines.first, direction: "from_supplier",
                                         on: Date.new(2026, 3, 10), base_cents: 10_000_00, withheld_cents: 200_00, reversal: false)
    expect { rows.sole.update!(withheld_cents: 1) }.to raise_error(ActiveRecord::RecordInvalid, /can.t be changed/)
    expect(code.reload).to be_posted
  end

  it "is settled by paying what is owed, in part or in full, and by a pay run" do
    approved = bill.approve!
    TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: supplier, account: account("1010"), paid_on: Date.new(2026, 3, 20), amount_cents: 5_000_00,
                                     applications: [ { document: approved, amount_cents: 5_000_00 } ])
    expect(approved.reload).to have_attributes(payment_status: "part_paid", amount_due: php(6_000))
    expect(TudlaAccounting::PayRun.due(organization, currency: "PHP").sole).to eq(approved)
    TudlaAccounting::PayRun.call(organization: organization, account: account("1010"), paid_on: Date.new(2026, 3, 25), bills: [ { document: approved, amount_cents: 6_000_00 } ])
    expect(approved.reload).to have_attributes(payment_status: "paid", amount_due: php(0))
  end

  it "gives a supplier credit a negative row, and takes it off what is owed" do
    approved = bill.approve!
    credit = bill(kind: "supplier_credit", cents: 1_000_00, credited_document: approved).approve!
    expect(postings(credit.entry)).to contain_exactly([ "2100-PHP", "debit", 1_100_00 ], [ "6000", "credit", 1_000_00 ], [ "1300", "credit", 120_00 ], [ "2300", "debit", 20_00 ])
    expect(rows.last).to have_attributes(base_cents: -1_000_00, withheld_cents: -20_00, reversal: false)
    expect(approved.reload.amount_due).to eq(php(9_900))
  end

  it "adds an opposite row dated the reversal when voided, keeping the first" do
    approved = bill.approve!
    approved.void!(on: Date.new(2026, 4, 2), reason: "Wrong supplier")
    expect(rows.map { |row| [ row.on, row.base_cents, row.withheld_cents, row.reversal ] }).to eq([ [ Date.new(2026, 3, 10), 10_000_00, 200_00, false ], [ Date.new(2026, 4, 2), -10_000_00, -200_00, true ] ])
    expect(rows.last).to have_attributes(entry: approved.entry, document_line: approved.lines.first, contact: supplier)
  end

  it "converts a foreign bill's tax, keeping the payable's foreign amount net" do
    foreign = described_class.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 3, 10), currency: "USD", exchange_rate: "60",
                                      lines_attributes: [ { description: "Licence", unit_price_cents: 100_00, account: account("6000"), withholding_code: code } ]).approve!
    expect(foreign).to have_attributes(withheld_cents: 2_00, payable_cents: 98_00, total_in_base: php(5_880))
    expect(postings(foreign.entry)).to contain_exactly([ "2100-USD", "credit", 5_880_00 ], [ "6000", "debit", 6_000_00 ], [ "2300", "credit", 120_00 ])
    expect(foreign.entry.details.find { |detail| detail.account.code == "2100-USD" }.foreign_exchange.other_currency_cents).to eq(98_00)
    expect(foreign.amount_due.cents).to eq(98_00)
    expect(rows.sole).to have_attributes(base_cents: 6_000_00, withheld_cents: 120_00)
    payment = TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: supplier, account: account("1020"), paid_on: Date.new(2026, 3, 20), exchange_rate: "60", amount_cents: 98_00,
                                               applications: [ { document: foreign, amount_cents: 98_00 } ])
    expect(payment).to be_persisted
    expect(foreign.reload.payment_status).to eq("paid")
  end

  it "balances the purchase journal and leaves the VAT report as it was, on either basis" do
    approved = bill.approve!
    books = TudlaAccounting::Reports::BooksOfAccounts.new(organization, from: year.children.order(:from_date).to_a[2], thru: year.children.order(:from_date).to_a[2])
    expect(books.book("general_ledger").pages.find { |ledger| ledger.account.code == "2300" }.totals).to include(debit: php(0), credit: php(200))
    page = books.book("purchases").pages.sole
    expect(page.balanced).to be(true)
    expect(page.rows.first.cells).to include(payable: php(11_000), purchases: php(10_000), input_vat: php(1_200), account_title: "Withholding payable", other: php(-200))
    from, thru = Time.zone.local(2026, 3, 1), Time.zone.local(2026, 3, 31).end_of_day
    expect(TudlaAccounting::TaxReport.call(organization, from: from, thru: thru, basis: :accrual)[:purchases]).to eq(base: php(10_000), tax: php(1_200))

    TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: supplier, account: account("1010"), paid_on: Date.new(2026, 3, 20), amount_cents: 5_500_00,
                                     applications: [ { document: approved, amount_cents: 5_500_00 } ])
    expect(TudlaAccounting::TaxReport.call(organization, from: from, thru: thru, basis: :cash)[:purchases]).to eq(base: php(5_000), tax: php(600))
  end

  it "says what is wrong with a line's code" do
    errors = ->(**attributes) { described_class.new({ organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 3, 10) }.merge(attributes)).tap(&:valid?).errors.full_messages }
    line = ->(withholding) { { description: "x", unit_price_cents: 1_00, account: account("6000"), withholding_code: withholding } }

    customer = TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer")
    sold = { description: "x", unit_price_cents: 1_00, account: account("4000"), withholding_code: code }
    expect(errors.call(kind: "sales_invoice", contact: customer, lines_attributes: [ sold ]).join).to include("record what a customer withholds on their payment")

    creditable_only = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WI100", name: "Rent", rate: "0.05", creditable_account: account("1200"))
    expect(errors.call(lines_attributes: [ line.call(creditable_only) ]).join).to include("WI100 has no account for tax withheld from suppliers")

    code.update!(active: false)
    expect(errors.call(lines_attributes: [ line.call(code) ]).join).to include("WC120 is inactive")

    other = create(:organization, currency: "PHP")
    TudlaAccounting::AccountsCreator.call([ { code: "2300", name: "Theirs", category: "liability" } ], other)
    theirs = TudlaAccounting::WithholdingCode.create!(organization: other, code: "WC010", name: "Theirs", rate: "0.1", payable_account: TudlaAccounting::Account.find_by!(organization: other))
    expect(errors.call(lines_attributes: [ line.call(theirs) ]).join).to include("must belong to the same organization")
  end

  it "keeps a line's inactive code on a draft saved again" do
    draft = bill
    code.update!(active: false)
    expect(draft.reload.update(notes: "Checked")).to be(true)
  end

  it "keeps a code's rate and accounts once tax is posted under it, and the code itself" do
    bill.approve!
    expect(code.update(rate: "0.03")).to be(false)
    expect(code.errors.full_messages).to eq([ "Tax has been posted under WC120, so its rate can't change; add a new code instead" ])
    code.reload
    expect(code.update(payable_account: nil)).to be(false)
    code.reload
    expect(code.update(name: "Certain contractors", active: false)).to be(true)
    expect(code).to be_used
    expect(code.destroy).to be(false)
  end

  it "counts a draft's line as using the code" do
    bill
    expect(code).to be_used
    expect(code).not_to be_posted
    expect(code.update(rate: "0.03")).to be(true)
  end
end
