require "rails_helper"

RSpec.describe TudlaAccounting::Reports::SummaryLists do
  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }
  let(:northwind) { contact("Northwind", "customer", tax_number: "111-222-333-000") }
  let(:aurora) { contact("Aurora", "customer") }
  let(:ledger) { contact("Ledger & Co", "supplier", tax_number: "222-333-444-000", address: "2 Made-up Road") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2200", name: "VAT", category: "liability" },
      { code: "2300", name: "Withholding", category: "liability" }, { code: "4000", name: "Sales", category: "income" },
      { code: "6000", name: "Fees", category: "expense" }, { code: "1500", name: "Equipment", category: "asset" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def contact(name, kind, **attrs) = TudlaAccounting::Contact.create!(organization: organization, name: name, kind: kind, **attrs)
  def code(text, kind, **attrs) = TudlaAccounting::TaxCode.create!({ organization: organization, code: text, name: text, kind: kind, rate: "0.12", account: account("2200") }.merge(attrs))
  def untaxed(text, kind, treatment) = TudlaAccounting::TaxCode.create!(organization: organization, code: text, name: text, kind: kind, rate: 0, treatment: treatment)
  def month(number) = TudlaAccounting::Period.leaf_periods_for_date(organization, Time.zone.local(2026, number, 15, 12)).first
  def report(from: 1, thru: 3) = described_class.new(organization, from: month(from), thru: month(thru))

  def document(kind, who, on, *lines, **attrs)
    posting = kind.in?(%w[bill supplier_credit]) ? "6000" : "4000"
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: who, issued_on: on, **attrs,
                                      lines_attributes: lines.map { |cents, tax_code, extra| { description: "Work", unit_price_cents: cents, account: account(posting), tax_code: tax_code, **extra.to_h } }).tap(&:approve!)
  end

  def amounts(row, *names) = names.map { |name| row.public_send(name).cents }

  it "lists sales by customer and month, in name order, split by treatment" do
    vat = code("OUT", :sales)
    zero = untaxed("ZR", :sales, :zero_rated)
    exempt = untaxed("EX", :sales, :exempt)
    document("sales_invoice", northwind, Date.new(2026, 1, 10), [ 1_000_00, vat ], [ 200_00, zero ], [ 50_00, exempt ])
    document("sales_invoice", northwind, Date.new(2026, 1, 20), [ 500_00, vat ])
    document("sales_invoice", northwind, Date.new(2026, 2, 5), [ 300_00, vat ])
    document("sales_invoice", aurora, Date.new(2026, 1, 15), [ 100_00, vat ])

    rows = report.sales
    expect(rows.map { |row| [ row.month, row.contact.name ] }).to eq([ [ Date.new(2026, 1, 1), "Aurora" ], [ Date.new(2026, 1, 1), "Northwind" ], [ Date.new(2026, 2, 1), "Northwind" ] ])
    expect(amounts(rows[1], :exempt, :zero_rated, :taxable, :tax, :total)).to eq([ 50_00, 200_00, 1_500_00, 180_00, 1_750_00 ])
    expect(report.total(:sales)).to include(taxable: Money.new(1_900_00, "PHP"), tax: Money.new(228_00, "PHP"))
    expect(report.purchases).to be_empty
    expect(report.difference(:sales)).to have_attributes(base: Money.new(0, "PHP"), tax: Money.new(0, "PHP"))
    expect(report(from: 3).sales).to be_empty
  end

  it "splits purchases by the code's type, leaves out tax withheld, and says which codes have none" do
    services = code("INS", :purchases, purchase_type: :services)
    capital = code("INC", :purchases, purchase_type: :capital_goods)
    goods = code("ING", :purchases, purchase_type: :other_goods)
    unset = code("INX", :purchases)
    exempt = untaxed("EXP", :purchases, :exempt)
    zero = untaxed("ZRP", :purchases, :zero_rated)
    withholding = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Contractors", rate: "0.02", payable_account: account("2300"))
    document("bill", ledger, Date.new(2026, 2, 10), [ 1_000_00, services, { withholding_code: withholding } ], [ 2_000_00, capital ], [ 300_00, goods ], [ 400_00, unset ], [ 50_00, exempt ], [ 60_00, zero ])

    row = report.purchases.sole
    expect(amounts(row, :exempt, :zero_rated, :services, :capital_goods, :other_goods, :not_set, :tax)).to eq([ 50_00, 60_00, 1_000_00, 2_000_00, 300_00, 400_00, 444_00 ])
    expect(row.total.cents).to eq(3_810_00)
    expect(report.codes_not_set).to eq([ unset ])
    expect(report.difference(:purchases)).to have_attributes(base: Money.new(0, "PHP"), tax: Money.new(0, "PHP"))
    expect(report.sales).to be_empty
  end

  it "counts a credit note and a void in their own months, as negatives" do
    vat = code("OUT", :sales)
    credited = document("sales_invoice", northwind, Date.new(2026, 1, 10), [ 500_00, vat ])
    voided = document("sales_invoice", northwind, Date.new(2026, 1, 11), [ 1_000_00, vat ])
    document("sales_credit", northwind, Date.new(2026, 2, 10), [ 100_00, vat ], credited_document: credited)
    voided.void!(on: Date.new(2026, 3, 5), reason: "Billed wrongly")

    expect(report.sales.map { |row| [ row.month.month, *amounts(row, :taxable, :tax) ] }).to eq([ [ 1, 1_500_00, 180_00 ], [ 2, -100_00, -12_00 ], [ 3, -1_000_00, -120_00 ] ])
    expect(report(from: 1, thru: 3).difference(:sales)).to have_attributes(base: Money.new(0, "PHP"), tax: Money.new(0, "PHP"))
  end

  it "leaves out a month that nets to nothing" do
    vat = code("OUT", :sales)
    invoice = document("sales_invoice", northwind, Date.new(2026, 1, 10), [ 1_000_00, vat ])
    invoice.void!(on: Date.new(2026, 1, 20), reason: "Billed wrongly")
    expect(report.sales).to be_empty
  end

  it "counts a line with no tax code as exempt, and says how much" do
    document("sales_invoice", northwind, Date.new(2026, 1, 10), [ 1_000_00, nil ])
    document("bill", ledger, Date.new(2026, 1, 10), [ 400_00, nil ])

    expect(amounts(report.sales.sole, :exempt, :taxable, :tax)).to eq([ 1_000_00, 0, 0 ])
    expect(report.uncoded(:sales).cents).to eq(1_000_00)
    expect(amounts(report.purchases.sole, :exempt, :services, :tax)).to eq([ 400_00, 0, 0 ])
    expect(report.uncoded(:purchases).cents).to eq(400_00)
    expect(report.difference(:sales).base.cents).to eq(0)
  end

  it "puts tax-coded lines on a typed entry in a row with no contact, last, so the list still ties" do
    vat = code("OUT", :sales)
    document("sales_invoice", northwind, Date.new(2026, 1, 10), [ 100_00, vat ])
    entry = TudlaAccounting::Entry.new(organization: organization, particulars: "Cash sale", transacted_at: Time.zone.local(2026, 1, 12, 12))
    entry.details.build(account: account("1000"), tally: :debit, amount_cents: 112_00, currency: "PHP", organization: organization)
    entry.details.build(account: account("4000"), tally: :credit, amount_cents: 100_00, currency: "PHP", organization: organization, tax_code: vat, tax_role: :base)
    entry.details.build(account: account("2200"), tally: :credit, amount_cents: 12_00, currency: "PHP", organization: organization, tax_code: vat, tax_role: :tax)
    entry.save!
    entry.post(entry.transacted_at)

    expect(report.sales.map { |row| row.contact&.name }).to eq([ "Northwind", nil ])
    expect(report.no_contact?(:sales)).to be(true)
    expect(report.no_contact?(:purchases)).to be(false)
    expect(report.difference(:sales).tax.cents).to eq(0)
  end

  it "converts a foreign bill into the organization's currency" do
    services = code("INS", :purchases, purchase_type: :services)
    document("bill", ledger, Date.new(2026, 1, 10), [ 100_00, services ], currency: "USD", exchange_rate: BigDecimal("60"))
    expect(amounts(report.purchases.sole, :services, :tax)).to eq([ 6_000_00, 720_00 ])
  end

  it "asks for a buyer's TIN only on a VAT sale, and a seller's on every purchase" do
    vat = code("OUT", :sales)
    zero = untaxed("ZR", :sales, :zero_rated)
    exempt = untaxed("EXP", :purchases, :exempt)
    overseas = contact("Overseas", "customer")
    nameless = contact("No Number", "supplier")
    document("sales_invoice", aurora, Date.new(2026, 1, 10), [ 100_00, vat ])
    document("sales_invoice", overseas, Date.new(2026, 1, 10), [ 100_00, zero ])
    document("sales_invoice", northwind, Date.new(2026, 1, 10), [ 100_00, vat ])
    document("bill", nameless, Date.new(2026, 1, 10), [ 100_00, exempt ])

    expect(report.missing_tin(:sales)).to eq([ "Aurora" ])
    expect(report.missing_tin(:purchases)).to eq([ "No Number" ])
  end

  it "reads a line in the month of the engine's time zone" do
    vat = code("OUT", :sales)
    allow(TudlaAccounting.configuration).to receive(:time_zone).and_return("Asia/Manila")
    document("sales_invoice", northwind, Date.new(2026, 2, 1), [ 100_00, vat ]) # midnight there is still January in UTC
    expect(report.sales.sole.month).to eq(Date.new(2026, 2, 1))
  end
end
