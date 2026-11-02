require "rails_helper"
require "roo"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Books of accounts", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }

  before do
    travel_to Time.zone.local(2026, 3, 25, 9)
    sign_in_as(organization)
  end

  after { travel_back }

  def text(selector) = css_select(selector).map { |node| node.text.squish }

  it "says there are no books without periods" do
    get routes.reports_books_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("to see reports.")
    get routes.reports_books_path(format: :pdf)
    expect(response).to have_http_status(:not_found)
    get routes.reports_books_path(format: :xlsx)
    expect(response).to have_http_status(:not_found)
  end

  it "shows a sample of each book's format with no financial year, for the year asked, and downloads it" do
    get routes.reports_books_path
    expect(css_select("a").map { |link| link["href"] }).to include(routes.reports_books_sample_path)

    get routes.reports_books_sample_path(book: "sales", year: 2027)
    expect(text("h1")).to eq([ "Books of accounts: sample format" ])
    expect(response.body).to include("For the period: January 1 to December 31, 2027", "These rows are examples, not your postings.")
    expect(text("[data-book-page] tbody tr").first).to eq("10 Jan 2027 SI-1001 Sample Client Inc. 000-000-000-000 100,000.00 100,000.00")
    expect(text("[data-check]").sole).to end_with("Balanced")
    links = css_select("a").map { |link| link["href"] }
    expect(links).to include(routes.reports_books_sample_path(format: :xlsx, year: 2027), routes.reports_books_sample_path(format: :pdf, book: "sales", year: 2027))

    get routes.reports_books_sample_path(year: "nonsense", book: "nonsense")
    expect(response.body).to include("General journal", "January 1 to December 31, 2026")

    get routes.reports_books_sample_path(format: :xlsx, year: 2027)
    expect(response.headers["Content-Disposition"]).to include("sample-books-of-accounts-2027.xlsx")
    file = Tempfile.new([ "sample", ".xlsx" ], binmode: true).tap { |tempfile| tempfile.write(response.body) && tempfile.close }
    cover = Roo::Excelx.new(file.path).sheet("Cover")
    expect((1..cover.last_row).map { |row| cover.cell(row, 1) }).to include("BOOKS OF ACCOUNTS – SAMPLE FORMAT", "A sample of each book's format: the rows are examples, not postings.")
    expect(cover.cell(cover.last_row - 3, 3)).to eq(6)

    allow(TudlaAccounting).to receive(:xlsx?).and_return(false)
    get routes.reports_books_sample_path
    expect(response.body).not_to include("Excel (all books)")
    get routes.reports_books_sample_path(format: :xlsx)
    expect(response).to have_http_status(:not_found)
  end

  context "with postings" do
    before do
      TudlaAccounting::PeriodCreator.call(organization, 2026)
      TudlaAccounting::AccountsCreator.call([
        { code: "1010", name: "Bank", category: "asset" }, { code: "3100", name: "Capital", category: "equity" }, { code: "6000", name: "Expenses", category: "expense" }
      ], organization)
      [ [ "Owner's capital", 2, "3100", "1010" ], [ "Bank charges", 20, "1010", "6000" ] ].each do |particulars, day, credit, debit|
        entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: particulars,
                                                             transacted_at: Time.zone.local(2026, 3, day, 12).iso8601,
                                                             details: [ { account_code: debit, amount: "PHP 500" }, { account_code: credit, amount: debit == "1010" ? "PHP 500" : "PHP -500" } ])
        entry.post(entry.transacted_at)
      end
      TudlaAccounting.configuration.books_header = ->(org) { "#{org.name.upcase}\nTIN: 000-000-000-000   |   1 Demo Street, Makati City" }
    end

    it "is listed with the reports, and shows the general journal for the year to date, page by page, under the books header" do
      get routes.reports_path
      expect(text("a .font-semibold")).to include("Books of accounts")

      get routes.reports_books_path
      expect(text("h1")).to eq([ "Books of accounts" ])
      expect(response.body).to include("General journal, January 1 to March 31, 2026: 1 page of 30 rows")
      expect(css_select("#book option").map { |option| option["value"] })
        .to eq(%w[general_journal general_ledger cash_receipts cash_disbursements sales purchases])
      expect(text("[data-books-name]")).to eq([ "BAYANIHAN CORP." ])
      expect(text("[data-book-page] header")).to eq([ "BAYANIHAN CORP. TIN: 000-000-000-000 | 1 Demo Street, Makati City General journal" ])
      expect(text("[data-page-number]")).to eq([ "1" ])
      expect(text("[data-book-page] tbody tr").first(3)).to eq([ "2 Mar 2026 #1 Bank 1010 500.00", "Capital 3100 500.00", "(Owner's capital)" ])
      expect(text("[data-totals]")).to eq([ "Total 1,000.00 1,000.00" ])
      expect(text("[data-check]")).to eq([ "Check (Debit = Credit): Balanced" ])
    end

    it "shows the ledger an account a page, and says when a book is empty or has no cash accounts to go by" do
      get routes.reports_books_path(book: "general_ledger")
      expect(text("[data-book-page] > div:first-of-type p:first-child")).to eq([ "Account title: Bank · Account code: 1010", "Account title: Capital · Account code: 3100",
                                                                                 "Account title: Expenses · Account code: 6000" ])
      expect(text("[data-page-number]")).to eq(%w[1 2 3])
      expect(text("[data-totals]").second).to eq("Total / ending balance 0.00 500.00 (500.00)")
      expect(css_select("[data-check]")).to be_empty

      get routes.reports_books_path(book: "cash_receipts")
      expect(response.body).to include("No cash accounts are set", "Nothing in the cash receipts journal for these months.")
      get routes.reports_books_path(book: "sales")
      expect(response.body).not_to include("No cash accounts are set")
      get routes.reports_books_path(book: "nonsense")
      expect(response.body).to include("General journal, January 1 to March 31, 2026")
    end

    it "downloads every book in one Excel workbook, for the months shown, when the host has caxlsx" do
      march = TudlaAccounting::Period.leaf_periods_for_date(organization, Time.zone.local(2026, 3, 15, 12)).first
      get routes.reports_books_path(book: "sales", from_id: march.id, thru_id: march.id)
      expect(css_select("a").map { |link| link["href"] }).to include(routes.reports_books_path(format: :xlsx, from_id: march.id, thru_id: march.id))

      get routes.reports_books_path(format: :xlsx, from_id: march.id, thru_id: march.id)
      expect(response.media_type).to eq(Mime[:xlsx].to_s)
      expect(response.headers["Content-Disposition"]).to include("books-of-accounts-2026-03-01-to-2026-03-31.xlsx")
      file = Tempfile.new([ "books", ".xlsx" ], binmode: true).tap { |tempfile| tempfile.write(response.body) && tempfile.close }
      workbook = Roo::Excelx.new(file.path)
      expect(workbook.sheets.first(3)).to eq(%w[Cover GeneralJournal GeneralLedger])
      expect(workbook.sheet("Cover").row(1).first).to eq("BAYANIHAN CORP.")

      allow(TudlaAccounting).to receive(:xlsx?).and_return(false)
      get routes.reports_books_path
      expect(response.body).not_to include("Excel (all books)")
      get routes.reports_books_path(format: :xlsx)
      expect(response).to have_http_status(:not_found)
    end
  end
end
