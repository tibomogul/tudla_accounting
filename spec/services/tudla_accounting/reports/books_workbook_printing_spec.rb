require "rails_helper"
require "open3"
require_relative "../../../support/configuration"

# Prints the books workbook through LibreOffice (soffice, in the Docker image; CI hasn't
# it, so this is skipped there) to check that each 30-row page of each book, at the scale
# the workbook sets, prints on one A4 sheet: a sheet for the cover, then one for each
# page, each with its header, page number, TOTAL row and check.
RSpec.describe TudlaAccounting::Reports::BooksWorkbook, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:soffice) { ENV["PATH"].split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "soffice") }.find { |path| File.executable?(path) } }
  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:march) { year.children.order(:from_date).to_a[2] }
  let(:books) { TudlaAccounting::Reports::BooksOfAccounts.new(organization, from: march, thru: march) }

  before do
    skip "LibreOffice (soffice) isn't installed" unless soffice

    # The longest header the books are likely to have: a name and two more lines.
    TudlaAccounting.configuration.books_header = ->(org) { "#{org.name}\nTIN: 000-000-000-000   |   1 Demo Street, Barangay San Lorenzo, Makati City 1223\nRDO No. 050 – South Makati" }
    TudlaAccounting.configuration.cash_account_codes = %w[1010]
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "1500", name: "Equipment", category: "asset" }, { code: "2200", name: "VAT", category: "liability" },
      { code: "3100", name: "Capital", category: "equity" }, { code: "4000", name: "Sales", category: "income" },
      { code: "6000", name: "Office supplies and other administrative expenses", category: "expense" }
    ], organization)
    TudlaAccounting::TaxCode.create!(organization: organization, code: "VAT12", name: "VAT", kind: :sales, rate: "0.12", account: account("2200"))
    customer = TudlaAccounting::Contact.create!(organization: organization, name: "Sampaguita Foods and General Merchandise Corporation", kind: "customer", tax_number: "111-222-333-000")
    35.times do |index|
      day = (index % 28) + 1
      book("Depreciation of office equipment for the month, per schedule #{index + 1}", day,
           [ { account_code: "6000", amount: "PHP 1234567.89" }, { account_code: "1500", amount: "PHP -1234567.89" } ])
      book("Cash sale to a walk-in customer, official receipt #{index + 1}", day, [ { account_code: "1010", amount: "PHP 1120" }, { account_code: "4000", amount: "PHP 1000", tax_code: "VAT12" } ])
      TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: customer, issued_on: Date.new(2026, 3, day),
                                        lines_attributes: [ { description: "Services", unit_price_cents: 9_876_543_21, account: account("4000"), tax_code: TudlaAccounting::TaxCode.find_by!(code: "VAT12") } ]).approve!
    end
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def book(particulars, day, details)
    entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: particulars,
                                                         transacted_at: Time.zone.local(2026, 3, day, 12).iso8601, details: details)
    entry.post(entry.transacted_at)
  end

  it "prints each page of each book on one A4 sheet" do
    sheets = Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "books.xlsx"), described_class.new(books).to_xlsx)
      output, status = Open3.capture2e(soffice, "-env:UserInstallation=file://#{dir}/profile", "--headless", "--convert-to", "pdf", "--outdir", dir, File.join(dir, "books.xlsx"))
      expect(status).to be_success, output
      PDF::Reader.new(File.join(dir, "books.pdf")).pages.map { |page| [ page.attributes[:MediaBox], page.text.squish ] }
    end

    expected = books.books.flat_map { |each| each.pages.empty? ? [ [ each, nil ] ] : each.pages.map { |page| [ each, page ] } }
    expect(books.books.map { |each| [ each.key, each.pages.size ] }).to include([ "general_journal", 4 ], [ "cash_receipts", 2 ], [ "sales", 2 ])
    expect(sheets.size).to eq(1 + expected.size), "#{sheets.size} sheets printed for #{1 + expected.size} pages"
    expect(sheets.first.last).to include("BOOKS OF ACCOUNTS", "Total pages")
    sheets.drop(1).zip(expected).each do |(media_box, text), (book, page)|
      width, height = media_box.last(2).map(&:round)
      expect([ width, height ]).to eq(book.key == "general_ledger" ? [ 595, 842 ] : [ 842, 595 ]), "#{book.title} page #{page&.number} isn't on A4 the right way round"
      expect(text).to start_with("Bayanihan Corp.").and include(book.title.upcase, "Page No.: #{page&.number}")
      next unless page

      expect(text).to include("TOTAL"), "#{book.title} page #{page.number} lost its TOTAL row"
      expect(text).to end_with("Balanced") if book.check
    end
  end
end
