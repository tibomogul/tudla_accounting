require "rails_helper"
require "roo"

RSpec.describe TudlaAccounting::Reports::Withholding, type: :service do
  let(:organization) { create(:organization, currency: "PHP") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:months) { year.children.order(:from_date).to_a }
  let(:first_quarter) { described_class.new(organization, from: months[0], thru: months[2]) }
  let(:second_quarter) { described_class.new(organization, from: months[3], thru: months[5]) }
  let(:supplier) { TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier", tax_number: "444-555-666-000") }
  let(:untaxed) { TudlaAccounting::Contact.create!(organization: organization, name: "Aircon Guy", kind: "supplier") }
  let(:customer) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer", tax_number: "111-222-333-000") }
  let(:wc120) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Contractors", rate: "0.02", payable_account: account("2300"), creditable_account: account("1200")) }
  let(:wc010) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC010", name: "Professionals", rate: "0.1", payable_account: account("2300")) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "1200", name: "Creditable tax", category: "asset" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2300", name: "Withholding payable", category: "liability" }, { code: "6000", name: "Fees", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def php(amount) = Money.from_amount(BigDecimal(amount.to_s), "PHP")

  def bill(on, cents: 10_000_00, code: wc120, contact: supplier, kind: "bill", **attributes)
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: contact, issued_on: on,
                                      lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account("6000"), withholding_code: code } ], **attributes).approve!
  end

  def receive(on, withheld: 200_00)
    TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: customer, account: account("1010"), paid_on: on, amount_cents: 9_800_00, withholdings: [ { code: wc120, withheld_cents: withheld } ])
  end

  def remit(on, cents)
    entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Paid the BIR", transacted_at: on.in_time_zone.change(hour: 12).iso8601,
                                                         details: [ { account_code: "2300", amount: "PHP #{-cents / 100}" }, { account_code: "1010", amount: "PHP #{-cents / 100}" } ])
    entry.post(entry.transacted_at)
  end

  it "sums by code and month, and lists by supplier and code, netting a credit and leaving out what nets to nothing" do
    bill(Date.new(2026, 1, 10))
    original = bill(Date.new(2026, 3, 10))
    bill(Date.new(2026, 3, 15), kind: "supplier_credit", cents: 1_000_00, credited_document: original)
    bill(Date.new(2026, 2, 20), code: wc010, contact: untaxed, cents: 5_000_00)
    voided = bill(Date.new(2026, 2, 21), code: wc010, contact: supplier, cents: 3_000_00)
    voided.void!(on: Date.new(2026, 2, 25), reason: "Wrong")

    expect(first_quarter.months).to eq([ Date.new(2026, 1, 1), Date.new(2026, 2, 1), Date.new(2026, 3, 1) ])
    summary = first_quarter.summary("from_supplier")
    expect(summary.map { |row| [ row.code.code, row.months, row.base, row.withheld ] }).to eq([
      [ "WC010", [ php(0), php(500), php(0) ], php(5_000), php(500) ],
      [ "WC120", [ php(200), php(0), php(180) ], php(19_000), php(380) ]
    ])
    expect(first_quarter.month_totals("from_supplier")).to eq([ php(200), php(500), php(180) ])
    expect(first_quarter.total("from_supplier")).to eq(php(880))
    expect(first_quarter.qap.map { |row| [ row.contact.name, row.code.code, row.base, row.withheld ] }).to eq([
      [ "Aircon Guy", "WC010", php(5_000), php(500) ], [ "Ledger & Co", "WC120", php(19_000), php(380) ]
    ])
  end

  it "ties to the accounts in each quarter when a void and a credit fall in a later one" do
    voided = bill(Date.new(2026, 3, 10))
    kept = bill(Date.new(2026, 3, 11))
    voided.void!(on: Date.new(2026, 4, 2), reason: "Wrong")
    bill(Date.new(2026, 5, 1), kind: "supplier_credit", cents: 1_000_00, credited_document: kept)
    paid = receive(Date.new(2026, 3, 20))
    paid.void!(on: Date.new(2026, 4, 3), reason: "Bounced")

    expect(first_quarter.checks("from_supplier").sole).to have_attributes(account: account("2300"), listed: php(400), movement: php(400), difference: php(0))
    expect(second_quarter.checks("from_supplier").sole).to have_attributes(listed: php(-220), movement: php(-220), settled: php(0), difference: php(0))
    expect(first_quarter.checks("by_customer").sole).to have_attributes(account: account("1200"), listed: php(200), movement: php(200), difference: php(0))
    expect(second_quarter.checks("by_customer").sole).to have_attributes(listed: php(-200), movement: php(-200), settled: php(0), difference: php(0))
    expect(second_quarter.qap.sole).to have_attributes(contact: supplier, base: php(-11_000), withheld: php(-220))
  end

  it "expects a payment to the tax authority, leaving no difference, while tax entered by hand still shows" do
    bill(Date.new(2026, 1, 10))
    remit(Date.new(2026, 2, 10), 200_00)
    expect(first_quarter.checks("from_supplier").sole).to have_attributes(listed: php(200), movement: php(0), settled: php(200), difference: php(0))
    remit(Date.new(2026, 3, 10), -50_00) # a credit to the account in an entry that withheld nothing
    expect(first_quarter.checks("from_supplier").sole).to have_attributes(movement: php(50), settled: php(200), difference: php(50))
  end

  it "lists only marked certificates in the SAWT, saying what it leaves out" do
    marked, waiting = receive(Date.new(2026, 1, 20)), receive(Date.new(2026, 2, 20), withheld: 150_00)
    bounced = receive(Date.new(2026, 3, 20), withheld: 100_00)
    bounced.void!(on: Date.new(2026, 4, 3), reason: "Bounced")
    TudlaAccounting::WithheldTax.find_by!(payment: marked).mark_certificate!(on: Date.new(2026, 4, 5))
    expect(waiting).to be_persisted

    expect(first_quarter.sawt.map { |row| [ row.contact.name, row.code.code, row.base, row.withheld ] }).to eq([ [ "Northwind", "WC120", php(10_000), php(200) ] ])
    expect(first_quarter).to have_attributes(waiting: php(150), reversed: php(100))
    expect(first_quarter.total("by_customer")).to eq(php(450))
    expect(second_quarter).to have_attributes(sawt: [], waiting: php(0), reversed: php(-100))
  end

  describe "the tables" do
    def workbook(table)
      file = Tempfile.new([ "withholding", ".xlsx" ], binmode: true)
      file.write(table.to_xlsx("Sheet"))
      file.close
      Roo::Excelx.new(file.path)
    end

    before do
      bill(Date.new(2026, 1, 10))
      bill(Date.new(2026, 2, 20), code: wc010, contact: untaxed, cents: 5_000_00)
      TudlaAccounting::WithheldTax.find_by!(payment: receive(Date.new(2026, 1, 20))).mark_certificate!(on: Date.new(2026, 4, 5))
      receive(Date.new(2026, 2, 20), withheld: 150_00)
    end

    it "lays the QAP out with a total, flagging the missing TIN, as numbers in Excel" do
      table = TudlaAccounting::Reports::Tables.qap(first_quarter)
      expect(table.to_csv.lines.map(&:chomp)).to eq([
        "No.,TIN,Payee,Code,Rate %,Income,Tax withheld,Note", "1,,Aircon Guy,WC010,10.0,5000.00,500.00,No TIN", "2,444-555-666-000,Ledger & Co,WC120,2.0,10000.00,200.00,", ",,Total,,,15000.00,700.00,"
      ])
      expect(workbook(table).row(3)).to eq([ 2.0, "444-555-666-000", "Ledger & Co", "WC120", 2.0, 10_000.0, 200.0, nil ])
    end

    it "lays the SAWT out with what it leaves out" do
      expect(TudlaAccounting::Reports::Tables.sawt(first_quarter).to_csv.lines.map(&:chomp)).to eq([
        "No.,TIN,Withholding agent,Code,Rate %,Income,Tax withheld,Note", "1,111-222-333-000,Northwind,WC120,2.0,10000.00,200.00,", ",,Total,,,10000.00,200.00,",
        ",,Not listed: waiting for a certificate,,,,150.00,", ",,Not listed: since reversed,,,,0.00,"
      ])
    end

    it "lays the summary out by code and month, with the accounts' movement" do
      expect(TudlaAccounting::Reports::Tables.withholding_summary(first_quarter).to_csv.lines.map(&:chomp)).to eq([
        "Section,Code,Name,Rate %,Jan 2026,Feb 2026,Mar 2026,Income,Tax withheld",
        "Withheld from suppliers,WC010,Professionals,10.0,0.00,500.00,0.00,5000.00,500.00",
        "Withheld from suppliers,WC120,Contractors,2.0,200.00,0.00,0.00,10000.00,200.00",
        "Withheld from suppliers,,Total,,200.00,500.00,0.00,15000.00,700.00",
        "Withheld from suppliers,2300,Withholding payable: account's movement,,,,,,700.00",
        "Withheld from suppliers,2300,Withholding payable: paid to the tax authority,,,,,,0.00",
        "Withheld from suppliers,2300,Withholding payable: difference,,,,,,0.00",
        "Withheld by customers,WC120,Contractors,2.0,200.00,150.00,0.00,17500.00,350.00",
        "Withheld by customers,,Total,,200.00,150.00,0.00,17500.00,350.00",
        "Withheld by customers,1200,Creditable tax: account's movement,,,,,,350.00",
        "Withheld by customers,1200,Creditable tax: claimed against tax due,,,,,,0.00",
        "Withheld by customers,1200,Creditable tax: difference,,,,,,0.00"
      ])
    end
  end
end
