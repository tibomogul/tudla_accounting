require "rails_helper"
require_relative "../../../support/configuration"

RSpec.describe TudlaAccounting::Reports::BooksOfAccounts, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:months) { year.children.order(:from_date).to_a }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer", tax_number: "111-222-333-000") }
  let(:cloudware) { TudlaAccounting::Contact.create!(organization: organization, name: "Cloudware", kind: "supplier", tax_number: "444-555-666-000") }
  let(:books) { described_class.new(organization, from: months[2], thru: months[2]) }

  before do
    TudlaAccounting.configuration.cash_account_codes = %w[1000]
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash and bank", category: "asset", children: [ { code: "1010", name: "Bank", category: "asset" }, { code: "1020", name: "Petty cash", category: "asset" } ] },
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "1200", name: "Creditable withholding tax", category: "asset" },
      { code: "1500", name: "Equipment", category: "asset" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "2200", name: "VAT", category: "liability" }, { code: "3100", name: "Capital", category: "equity" },
      { code: "4000", name: "Sales", category: "income" }, { code: "6000", name: "Expenses", category: "expense" }
    ], organization)
    { "VAT12" => [ :sales, "0.12", :standard ], "ZR" => [ :sales, "0", :zero_rated ], "EX" => [ :sales, "0", :exempt ], "IN12" => [ :purchases, "0.12", :standard ] }
      .each do |code, (kind, rate, treatment)|
        TudlaAccounting::TaxCode.create!(organization: organization, code: code, name: code, kind: kind, rate: rate, treatment: treatment, account: (account("2200") if rate != "0"))
      end
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def php(amount) = Money.from_amount(BigDecimal(amount.to_s), "PHP")

  def book(particulars, day, details, month: 3)
    entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: particulars,
                                                         transacted_at: Time.zone.local(2026, month, day, 12).iso8601, details: details)
    entry.post(entry.transacted_at)
    entry
  end

  def document(kind, contact, day, lines, reference: nil)
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: contact, issued_on: Date.new(2026, 3, day), reference: reference,
                                      lines_attributes: lines.map { |description, cents, code, tax| { description: description, unit_price_cents: cents, account: account(code), tax_code: tax && TudlaAccounting::TaxCode.find_by!(code: tax) } }).approve!
  end

  def cells(book_key) = books.book(book_key).pages.flat_map(&:rows).map { |row| row.cells.transform_values { |value| value.is_a?(Money) ? value.format(symbol: false) : value } }

  context "with a month's transactions" do
    before do
      book("Owner's capital", 2, [ { account_code: "1010", amount: "PHP 10000" }, { account_code: "3100", amount: "PHP 10000" } ], month: 1)
      invoice = document("sales_invoice", northwind, 2, [ [ "Services", 1_000_00, "4000", "VAT12" ], [ "Export", 500_00, "4000", "ZR" ], [ "Books", 200_00, "4000", "EX" ] ])
      document("sales_credit", northwind, 5, [ [ "Discount", 100_00, "4000", "VAT12" ] ])
      document("bill", cloudware, 3, [ [ "Supplies", 1_000_00, "6000", "IN12" ], [ "Laptop", 2_000_00, "1500", "IN12" ] ], reference: "S-555")
      TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1010"), paid_on: Date.new(2026, 3, 20),
                                       amount_cents: 1_820_00, reference: "OR-0001", applications: [ { document: invoice, amount_cents: 1_820_00 } ])
      book("Cash sale", 21, [ { account_code: "1010", amount: "PHP 1120" }, { account_code: "4000", amount: "PHP 1000", tax_code: "VAT12" } ])
      book("Fee, 2% withheld", 22, [ { account_code: "1010", amount: "PHP 980" }, { account_code: "1200", amount: "PHP 20" }, { account_code: "4000", amount: "PHP 1000" } ])
      book("Office supplies", 23, [ { account_code: "6000", amount: "PHP 500", tax_code: "IN12" }, { account_code: "1020", amount: "PHP -560" } ])
      book("Cash to petty cash", 24, [ { account_code: "1020", amount: "PHP 100" }, { account_code: "1010", amount: "PHP -100" } ])
      book("Depreciation", 31, [ { account_code: "6000", amount: "PHP 50" }, { account_code: "1500", amount: "PHP -50" } ])
    end

    it "puts each entry in one book: cash first, then invoices and bills, the rest in the general journal" do
      entries = TudlaAccounting::Entry.where(organization: organization).where.not(posted_at: nil).order(:posted_at, :id)
      expect(entries.map { |entry| [ entry.particulars.split(" – ").first, books.book_key(entry) ] }).to eq([
        [ "Owner's capital", "cash_receipts" ], [ "Invoice INV-0001", "sales" ], [ "Bill BILL-0001", "purchases" ], [ "Credit note CN-0001", "sales" ],
        [ "Payment from Northwind (INV-0001)", "cash_receipts" ], [ "Cash sale", "cash_receipts" ], [ "Fee, 2% withheld", "cash_receipts" ],
        [ "Office supplies", "cash_disbursements" ], [ "Cash to petty cash", "general_journal" ], [ "Depreciation", "general_journal" ]
      ])
      expect(books.books.map(&:key)).to eq(described_class::BOOKS.keys)
      expect(books.period_label).to eq("March 1 to March 31, 2026")
    end

    it "lays out the sales journal by tax treatment, a credit note negative, with each customer's TIN" do
      expect(cells("sales")).to eq([
        { date: Date.new(2026, 3, 2), reference: "INV-0001", party: "Northwind", tin: "111-222-333-000", receivable: "1,820.00", vatable: "1,000.00", zero_rated: "500.00",
          exempt: "200.00", output_vat: "120.00" },
        { date: Date.new(2026, 3, 5), reference: "CN-0001", party: "Northwind", tin: "111-222-333-000", receivable: "-112.00", vatable: "-100.00", output_vat: "-12.00" }
      ])
      page = books.book("sales").pages.sole
      expect(page.totals.transform_values(&:to_s)).to eq(receivable: "1708.00", vatable: "900.00", zero_rated: "500.00", exempt: "200.00", output_vat: "108.00")
      expect(page).to have_attributes(number: 1, balanced: true)
    end

    it "lays out the purchases journal with the supplier's invoice number, and other accounts apart" do
      expect(cells("purchases")).to eq([ { date: Date.new(2026, 3, 3), reference: "S-555", party: "Cloudware", tin: "444-555-666-000", payable: "3,360.00", purchases: "1,000.00",
                                           input_vat: "360.00", account_title: "Equipment", other: "2,000.00" } ])
    end

    it "lays out cash received and paid, an amount on the other side negative, so cash equals the rest" do
      expect(cells("cash_receipts")).to eq([
        { date: Date.new(2026, 1, 2), reference: "#1", particulars: "Owner's capital", cash: "10,000.00", account_title: "Capital", other: "10,000.00" },
        { date: Date.new(2026, 3, 20), reference: "OR-0001", particulars: "Payment from Northwind (INV-0001)", cash: "1,820.00", receivable: "1,820.00" },
        { date: Date.new(2026, 3, 21), reference: "#6", particulars: "Cash sale", cash: "1,120.00", sales: "1,000.00", output_vat: "120.00" },
        { date: Date.new(2026, 3, 22), reference: "#7", particulars: "Fee, 2% withheld", cash: "980.00", sales: "1,000.00", account_title: "Creditable withholding tax", other: "-20.00" }
      ].drop(1))
      expect(books.book("cash_receipts").pages.sole).to have_attributes(balanced: true, totals: include(cash: php(3_920), other: php(-20)))
      expect(cells("cash_disbursements")).to eq([ { date: Date.new(2026, 3, 23), reference: "#8", particulars: "Office supplies", cash: "560.00", expenses: "500.00", input_vat: "60.00" } ])
    end

    it "writes the general journal debits first, then the credits indented, then the explanation" do
      rows = books.book("general_journal").pages.sole.rows
      expect(rows.map(&:kind)).to eq(%i[line credit_line explanation line credit_line explanation])
      expect(rows.first(3).map(&:cells)).to eq([
        { date: Date.new(2026, 3, 24), reference: "#9", particulars: "Petty cash", account_code: "1020", debit: php(100) },
        { particulars: "Bank", account_code: "1010", credit: php(100) },
        { particulars: "(Cash to petty cash)" }
      ])
      expect(books.book("general_journal").pages.sole).to have_attributes(totals: { debit: php(150), credit: php(150) }, balanced: true)
    end

    it "keeps a ledger page an account, bringing forward its balance, debits positive and credits negative" do
      pages = books.book("general_ledger").pages
      expect(pages.map { |page| [ page.number, page.account.code ] }.first(3)).to eq([ [ 1, "1010" ], [ 2, "1020" ], [ 3, "1100-PHP" ] ])
      bank = pages.first
      expect(bank.rows.first.cells).to eq(date: Date.new(2026, 3, 1), particulars: "Balance brought forward", balance: php(10_000))
      expect(bank.rows.second.cells).to include(reference: "OR-0001", debit: php(1_820), balance: php(11_820))
      expect(bank).to have_attributes(closing: php(13_820), totals: { debit: php(3_920), credit: php(100) })
      capital = pages.find { |page| page.account.code == "3100" }
      expect(capital.rows.map(&:cells)).to eq([ { date: Date.new(2026, 3, 1), particulars: "Balance brought forward", balance: php(-10_000) } ])
      expect(capital.closing).to eq(php(-10_000))
    end
  end

  it "fills pages of 30 rows, keeping each entry's rows together, and continues a ledger account over pages" do
    31.times { |index| book("Depreciation #{index + 1}", (index % 28) + 1, [ { account_code: "6000", amount: "PHP 10" }, { account_code: "1500", amount: "PHP -10" } ]) }

    journal = books.book("general_journal").pages
    expect(journal.map { |page| [ page.number, page.rows.size, page.totals[:debit] ] }).to eq([ [ 1, 30, php(100) ], [ 2, 30, php(100) ], [ 3, 30, php(100) ], [ 4, 3, php(10) ] ])
    ledger = books.book("general_ledger").pages
    expect(ledger.map { |page| [ page.number, page.account.code, page.rows.size ] }).to eq([ [ 1, "1500", 30 ], [ 2, "1500", 3 ], [ 3, "6000", 30 ], [ 4, "6000", 3 ] ])
    expect(ledger.second.rows.first.cells).to eq(date: nil, particulars: "Balance brought forward", balance: php(-290))
    expect(ledger.second.closing).to eq(php(-310))
  end

  it "names the months across two years, and has empty books for months without postings" do
    TudlaAccounting::PeriodCreator.call(organization, 2027)
    january = TudlaAccounting::Period.leaf_periods_for_date(organization, Time.zone.local(2027, 1, 15, 12)).first
    spanning = described_class.new(organization, from: months.last, thru: january)
    expect(spanning.period_label).to eq("December 1, 2026 to January 31, 2027")
    expect(spanning.books.map { |each| each.pages.size }).to all(eq(0))
  end
end
