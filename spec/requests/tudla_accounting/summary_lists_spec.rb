require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Summary lists of sales and purchases", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }

  before do
    travel_to Time.zone.local(2026, 5, 25, 9)
    sign_in_as(organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def text(selector) = css_select(selector).map { |node| node.text.squish }

  context "without a financial year" do
    it "says so, and has nothing to download" do
      [ routes.reports_sales_list_path, routes.reports_purchases_list_path ].each do |path|
        get path
        expect(response.body).to include("to see reports.")
        get "#{path}.csv"
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  context "with a financial year" do
    let(:output) { TudlaAccounting::TaxCode.create!(organization: organization, code: "OUT", name: "VAT", kind: :sales, rate: "0.12", account: account("2200")) }
    let(:input) { TudlaAccounting::TaxCode.create!(organization: organization, code: "INX", name: "Input", kind: :purchases, rate: "0.12", account: account("2200")) }
    let(:customer) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer") }
    let(:supplier) { TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier", address: "2 Made-up Road\nQuezon City", postal_code: "1100") }

    before do
      TudlaAccounting::PeriodCreator.call(organization, 2026)
      TudlaAccounting::AccountsCreator.call([
        { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
        { code: "2200", name: "VAT", category: "liability" }, { code: "4000", name: "Sales", category: "income" }, { code: "6000", name: "Fees", category: "expense" }
      ], organization)
    end

    def document(kind, who, cents, tax_code, code)
      TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: who, issued_on: Date.new(2026, 5, 10),
                                        lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account(code), tax_code: tax_code } ]).approve!
    end

    it "is among the reports, and shows an empty list for this quarter" do
      get routes.reports_path
      expect(response.body).to include("Summary list of sales", "Summary list of purchases")
      get routes.reports_sales_list_path
      expect(response.body).to include("Nothing posted in these months.", "1 Apr 2026")
      expect(text("[data-confirm-rdo]").sole).to include("Bayanihan Corp.", "isn't confirmed", "Revenue District Office")
    end

    it "shows the sales list with what needs attention, the filer's details and the tie to the tax summary" do
      TudlaAccounting.configuration.withholding_agent = ->(org) { { name: "#{org.name} (registered)", tin: "000-111-222-00000", address: "1 Demo Street" } }
      document("sales_invoice", customer, 1_000_00, output, "4000")
      document("sales_invoice", customer, 50_00, nil, "4000")

      get routes.reports_sales_list_path
      expect(text("[data-filer]").sole).to eq("Bayanihan Corp. (registered) · TIN 000-111-222-00000 · 1 Demo Street")
      expect(text("[data-list-row] td").first(7)).to eq([ "May 2026", "No TIN", "Northwind", "50.00", "0.00", "1,000.00", "0.00" ])
      expect(text("[data-list-row] td").last(2)).to eq([ "120.00", "1,050.00" ])
      expect(text("[data-missing-tin]").sole).to include("No TIN for Northwind.")
      expect(text("[data-uncoded]").sole).to include("50.00")
      expect(css_select("[data-no-contact], [data-codes-not-set], [data-cash-basis]")).to be_empty
      expect(text("[data-list-check]").sole).to include("amounts with a tax code0.00", "tax0.00")
    end

    it "doesn't double the full stop after a name that ends in one" do
      document("sales_invoice", TudlaAccounting::Contact.create!(organization: organization, name: "Tala Inc.", kind: "customer"), 100_00, output, "4000")
      get routes.reports_sales_list_path
      expect(text("[data-missing-tin]").sole).to eq("No TIN for Tala Inc. Add it on the contact before filing.")
    end

    it "shows the purchases list, flagging a code with no purchase type, with the seller's address" do
      document("bill", supplier, 1_000_00, input, "6000")

      get routes.reports_purchases_list_path
      expect(css_select("thead th").map { |cell| cell.text.squish }).to eq([ "Month", "TIN", "Seller", "Address", "Exempt", "Zero-rated", "Services", "Capital goods", "Other goods", "Not set", "Final VAT withheld", "Creditable input tax", "Non-creditable input tax", "Total purchases" ])
      expect(text("[data-list-row] td")).to include("2 Made-up Road Quezon City 1100", "120.00", "1,000.00")
      expect(text("[data-codes-not-set]").sole).to include("INX doesn't say")

      input.update!(purchase_type: :services)
      get routes.reports_purchases_list_path
      expect(css_select("thead th").map { |cell| cell.text.squish }).not_to include("Not set")
      expect(css_select("[data-codes-not-set]")).to be_empty
    end

    it "says a typed entry's lines have no contact, and that a cash-basis book won't match" do
      TudlaAccounting.configuration.tax_basis = :cash
      entry = TudlaAccounting::Entry.new(organization: organization, particulars: "Cash sale", transacted_at: Time.zone.local(2026, 5, 12, 12))
      entry.details.build(account: account("1000"), tally: :debit, amount_cents: 112_00, currency: "PHP", organization: organization)
      entry.details.build(account: account("4000"), tally: :credit, amount_cents: 100_00, currency: "PHP", organization: organization, tax_code: output, tax_role: :base)
      entry.details.build(account: account("2200"), tally: :credit, amount_cents: 12_00, currency: "PHP", organization: organization, tax_code: output, tax_role: :tax)
      entry.save!
      entry.post(entry.transacted_at)

      get routes.reports_sales_list_path
      expect(text("[data-no-contact]").sole).to include("no buyer to list them under")
      expect(text("[data-cash-basis]").sole).to include("won't match")
      expect(text("[data-list-row] td")).to include("No contact")
      expect(text("[data-list-check]").sole).to include("amounts with a tax code0.00", "tax0.00")
    end

    it "downloads the lists, and takes other months" do
      document("sales_invoice", customer, 1_000_00, output, "4000")
      document("bill", supplier, 1_000_00, input, "6000")

      get routes.reports_sales_list_path(format: :csv)
      expect(response.headers["Content-Disposition"]).to include("sales-list-2026-04-01-to-2026-06-30.csv")
      rows = CSV.parse(response.body)
      expect(rows.first).to eq([ "Month", "TIN", "Buyer", "Exempt", "Zero-rated", "VATable (before VAT)", "Final VAT withheld", "Output tax", "Total sales", "Note" ])
      expect(rows[1]).to eq([ "May 2026", nil, "Northwind", "0.00", "0.00", "1000.00", "0.00", "120.00", "1000.00", "No TIN" ])
      expect(rows[2]).to eq([ nil, nil, "Total", "0.00", "0.00", "1000.00", "0.00", "120.00", "1000.00", nil ])
      expect(rows[3]).to eq([ nil, nil, "Difference from the tax summary", nil, nil, nil, "0.00", "0.00", "0.00", nil ])

      get routes.reports_purchases_list_path(format: :csv)
      rows = CSV.parse(response.body)
      expect(rows.first).to eq([ "Month", "TIN", "Seller", "Address", "Exempt", "Zero-rated", "Services", "Capital goods", "Other goods", "Not set", "Final VAT withheld", "Creditable input tax", "Non-creditable input tax", "Total purchases", "Note" ])
      expect(rows[1]).to eq([ "May 2026", nil, "Ledger & Co", "2 Made-up Road Quezon City 1100", "0.00", "0.00", "0.00", "0.00", "0.00", "1000.00", "0.00", "120.00", "0.00", "1000.00", "No TIN" ])

      january = TudlaAccounting::Period.leaf_periods_for_date(organization, Time.zone.local(2026, 1, 15, 12)).first
      get routes.reports_sales_list_path(from_id: january.id, thru_id: january.id)
      expect(response.body).to include("Nothing posted in these months.")
    end

    it "doesn't run more queries with more contacts" do
      count = lambda do
        queries = 0
        counter = ->(*, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get routes.reports_purchases_list_path }
        queries
      end
      document("bill", supplier, 100_00, input, "6000")
      few = count.call
      5.times { |index| document("bill", TudlaAccounting::Contact.create!(organization: organization, name: "Supplier #{index}", kind: "supplier"), 100_00, input, "6000") }
      expect(count.call).to be <= few
    end
  end
end
