require "rails_helper"
require "roo"
require_relative "../../../support/configuration"

RSpec.describe TudlaAccounting::Reports::BooksWorkbook, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:march) { year.children.order(:from_date).to_a[2] }
  let(:books) { TudlaAccounting::Reports::BooksOfAccounts.new(organization, from: march, thru: march) }
  let(:bytes) { described_class.new(books).to_xlsx }
  let(:workbook) do
    file = Tempfile.new([ "books", ".xlsx" ], binmode: true)
    file.write(bytes)
    file.close
    Roo::Excelx.new(file.path)
  end

  before do
    TudlaAccounting.configuration.books_header = ->(org) { "#{org.name}\nTIN: 000-000-000-000   |   1 Demo Street, Makati City" }
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "1500", name: "Equipment", category: "asset" },
      { code: "3100", name: "Capital", category: "equity" }, { code: "6000", name: "Expenses", category: "expense" }
    ], organization)
  end

  def book(particulars, day, details)
    entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: particulars,
                                                         transacted_at: Time.zone.local(2026, 3, day, 12).iso8601, details: details)
    entry.post(entry.transacted_at)
  end

  def rows(sheet) = (1..workbook.sheet(sheet).last_row).map { |row| workbook.sheet(sheet).row(row) }
  def xml(path) = Zip::File.open_buffer(StringIO.new(bytes)).read(path)

  context "with a month's entries" do
    before do
      book("Owner's capital", 2, [ { account_code: "1010", amount: "PHP 10000" }, { account_code: "3100", amount: "PHP 10000" } ])
      11.times { |index| book("Depreciation #{index + 1}", index + 3, [ { account_code: "6000", amount: "PHP 10" }, { account_code: "1500", amount: "PHP -10" } ]) }
    end

    it "lists each book with its pages on a cover, then has a sheet a book" do
      expect(workbook.sheets).to eq(%w[Cover GeneralJournal GeneralLedger CashReceiptsJournal CashDisbursementsJournal SalesJournal PurchaseJournal])
      expect(rows("Cover")).to eq([
        [ "Bayanihan Corp.", nil, nil ], [ "TIN: 000-000-000-000   |   1 Demo Street, Makati City", nil, nil ], [ "BOOKS OF ACCOUNTS", nil, nil ],
        [ "For the period: March 1 to March 31, 2026", nil, nil ], [ nil, nil, nil ], [ "Book", "Sheet", "Pages" ],
        [ "General journal", "GeneralJournal", 2 ], [ "General ledger", "GeneralLedger", 4 ], [ "Cash receipts journal", "CashReceiptsJournal", 0 ],
        [ "Cash disbursements journal", "CashDisbursementsJournal", 0 ], [ "Sales journal", "SalesJournal", 0 ], [ "Purchase journal", "PurchaseJournal", 0 ],
        [ "Total pages", nil, 6 ], [ nil, nil, nil ], [ "Each page prints on a sheet of its own, numbered from 1 in each book, 30 rows to a page.", nil, nil ]
      ])
    end

    it "lays out each page of a journal as the template does, filled to 30 rows, with its total and check, and a page break after it" do
      journal = rows("GeneralJournal")
      expect(journal.first(8)).to eq([
        [ "Bayanihan Corp.", nil, nil, nil, nil, nil ], [ "TIN: 000-000-000-000   |   1 Demo Street, Makati City", nil, nil, nil, nil, nil ],
        [ "GENERAL JOURNAL", nil, nil, nil, nil, nil ], [ "For the period: March 1 to March 31, 2026", nil, nil, nil, nil, "Page No.: 1" ], [ nil ] * 6,
        [ "Date", "JV / Reference No.", "Particulars\n(Account Title & Explanation)", "Account Code", "Debit", "Credit" ],
        [ Date.new(2026, 3, 2), "#1", "Bank", "1010", 10_000.0, nil ], [ nil, nil, "Capital", "3100", nil, 10_000.0 ]
      ])
      expect(journal[8]).to eq([ nil, nil, "(Owner's capital)", nil, nil, nil ])
      expect(journal[35]).to eq([ nil, nil, "(Depreciation 9)", nil, nil, nil ]) # 10 entries of 3 rows fill the page
      expect(journal[36..37]).to eq([ [ nil, nil, "TOTAL", nil, 10_090.0, 10_090.0 ], [ nil, nil, "Check (Debit = Credit):", nil, "Balanced", nil ] ])
      expect(journal[38..41].map(&:first)).to eq([ "Bayanihan Corp.", "TIN: 000-000-000-000   |   1 Demo Street, Makati City", "GENERAL JOURNAL", "For the period: March 1 to March 31, 2026" ])
      expect(journal[41].last).to eq("Page No.: 2")
      expect(journal[44..51].map(&:third)).to eq([ "Expenses", "Equipment", "(Depreciation 10)", "Expenses", "Equipment", "(Depreciation 11)", nil, nil ])
      expect(journal[74]).to eq([ nil, nil, "TOTAL", nil, 20.0, 20.0 ])
      expect(journal.size).to eq(76)
      expect(workbook.sheet("GeneralJournal").cell(7, 1)).to eq(Date.new(2026, 3, 2))

      sheet = xml("xl/worksheets/sheet2.xml")
      expect(sheet).to include('<brk id="38" max="16383" man="1" />', '<pageSetup orientation="landscape" scale="91" paperSize="9" />', "<mergeCell ref='A4:E4'>")
      expect(xml("xl/styles.xml")).to include('formatCode="#,##0.00;(#,##0.00);-"', 'formatCode="mm/dd/yyyy"')
    end

    it "gives the ledger an account a page, with its code and closing balance, in portrait" do
      ledger = rows("GeneralLedger")
      expect(ledger[3]).to eq([ "Account Title:", "Bank", nil, "Account Code:", "1010", "Page No.: 1" ])
      expect(ledger[6]).to eq([ Date.new(2026, 3, 1), nil, "Balance brought forward", nil, nil, 0.0 ])
      expect(ledger[36]).to eq([ nil, nil, "TOTAL", 10_000.0, 0.0, 10_000.0 ])
      expect(ledger[37][0..3]).to eq([ "Bayanihan Corp.", nil, nil, nil ])
      expect(rows("GeneralLedger").map(&:third)).to include("Balance brought forward", "Depreciation 11")
      expect(xml("xl/worksheets/sheet3.xml")).to include('<pageSetup orientation="portrait" scale="71" paperSize="9" />')
    end

    it "says when a book has nothing for the months" do
      expect(rows("SalesJournal").last(2)).to eq([
        [ "Date", "Invoice No.", "Customer Name", "Customer TIN", "Accounts Receivable\n(Debit)", "Sales – VATable\n(Credit)", "Sales – Zero-Rated\n(Credit)",
          "Sales – VAT-Exempt\n(Credit)", "Output VAT\n(Credit)" ],
        [ "Nothing in the sales journal for these months.", nil, nil, nil, nil, nil, nil, nil, nil ]
      ])
      expect(rows("SalesJournal")[3].last).to eq("Page No.: ")
    end
  end

  context "with books in yen and no header set" do
    let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "JPY") }

    it "writes amounts without decimals, and the organization's name for a header" do
      TudlaAccounting.configuration.books_header = nil
      book("Capital", 2, [ { account_code: "1010", amount: "JPY 5000" }, { account_code: "3100", amount: "JPY 5000" } ])
      expect(xml("xl/styles.xml")).to include('formatCode="#,##0;(#,##0);-"')
      expect(rows("GeneralJournal").first).to eq([ "Bayanihan Corp.", nil, nil, nil, nil, nil ])
      expect(rows("GeneralJournal")[5]).to eq([ Date.new(2026, 3, 2), "#1", "Bank", "1010", 5000.0, nil ])
    end

    it "leaves the account of an empty ledger blank" do
      january = year.children.order(:from_date).first
      bytes.replace(described_class.new(TudlaAccounting::Reports::BooksOfAccounts.new(organization, from: january, thru: january)).to_xlsx)
      expect(rows("GeneralLedger")[3]).to eq([ "Account Title:", nil, nil, "Account Code:", nil, "Page No.: " ])
      expect(rows("Cover")[12]).to eq([ "Total pages", nil, 0 ])
    end
  end
end
