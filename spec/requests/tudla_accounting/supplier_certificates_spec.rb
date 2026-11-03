require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Certificates to suppliers", type: :request do
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
  def cells(selector) = css_select(selector).map { |row| row.css("td").map { |cell| cell.text.squish }.join(" ") }

  it "says when there are no three months in a row to certify" do
    get routes.reports_supplier_certificates_path
    expect(response.body).to include("to see reports.")
    get routes.reports_supplier_certificates_path(format: :pdf)
    expect(response).to have_http_status(:not_found)
  end

  context "with a financial year" do
    let(:code) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Contractors (corporate)", rate: "0.02", payable_account: account("2300")) }
    let(:ledger) { TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier", tax_number: "123-456-789-000", address: "2 Made-up Road\nQuezon City") }
    let(:aurora) { TudlaAccounting::Contact.create!(organization: organization, name: "Aurora Builders", kind: "supplier") }

    before do
      TudlaAccounting::PeriodCreator.call(organization, 2026)
      TudlaAccounting::AccountsCreator.call([
        { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2300", name: "Withholding payable", category: "liability" }, { code: "6000", name: "Fees", category: "expense" }
      ], organization)
    end

    def bill(contact, on, cents)
      TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: contact, issued_on: on, lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account("6000"), withholding_code: code } ]).approve!
    end

    it "asks for codes first, and isn't among the reports until there are some" do
      get routes.reports_path
      expect(response.body).not_to include("Certificates to suppliers")
      get routes.reports_supplier_certificates_path
      expect(response.body).to include("No withholding codes yet.")

      code
      get routes.reports_path
      expect(text("a .font-semibold")).to include("Certificates to suppliers (2307)")
      get routes.reports_supplier_certificates_path
      expect(response.body).to include("Nothing withheld from suppliers in these months.")
      expect(response.body).not_to include("All as PDF")
      get routes.reports_supplier_certificates_path(format: :pdf)
      expect(response).to have_http_status(:not_found)
    end

    it "lists this quarter's by default, warns of what's missing and says to check acceptance" do
      bill(ledger, Date.new(2026, 4, 10), 10_000_00)
      bill(aurora, Date.new(2026, 5, 10), 5_000_00)
      bill(ledger, Date.new(2026, 1, 10), 7_000_00)

      get routes.reports_supplier_certificates_path
      expect(css_select("#quarter option[selected]").map { |option| option["value"] }).to eq([ "2026-04-01" ])
      expect(text("#quarter option")).to include("Jan–Mar 2026", "Feb–Apr 2026", "Oct–Dec 2026")
      expect(cells("[data-certificate-row]").map { |row| row.sub(/ PDF\z/, "") }).to eq([ "No TIN Aurora Builders WC120 5,000.00 100.00", "123-456-789-000 Ledger & Co WC120 10,000.00 200.00" ])
      expect(text("[data-confirm-rdo]").sole).to include("Revenue District Office")
      expect(text("[data-missing-tin]").sole).to include("No TIN for Aurora Builders")
      expect(text("[data-missing-agent]").sole).to include("no TIN, address, ZIP code, signatory's name, signatory's title or signatory's TIN")
      expect(css_select("[data-negative]")).to be_empty
      links = css_select("a").map { |link| link["href"] }
      expect(links).to include(routes.reports_supplier_certificates_path(format: :pdf, quarter: "2026-04-01"), routes.reports_supplier_certificates_path(format: :pdf, quarter: "2026-04-01", contact_id: ledger.id))

      get routes.reports_supplier_certificates_path(quarter: "2026-01-01")
      expect(cells("[data-certificate-row]").sole).to include("Ledger & Co", "7,000.00")
      get routes.reports_supplier_certificates_path(quarter: "2026-02-01")
      expect(cells("[data-certificate-row]").map { |row| row.split.last(3).first }).to eq([ "10,000.00" ])

      get routes.reports_supplier_certificates_path(quarter: "nonsense")
      expect(response).to have_http_status(:not_found)
      get routes.reports_supplier_certificates_path(quarter: "2026-11-01")
      expect(response).to have_http_status(:not_found)
    end

    it "explains a negative certificate" do
      bill(ledger, Date.new(2026, 1, 10), 10_000_00).void!(on: Date.new(2026, 4, 2), reason: "Entered twice")
      get routes.reports_supplier_certificates_path
      expect(cells("[data-certificate-row]").sole).to include("(10,000.00)", "(200.00)")
      expect(text("[data-negative]").sole).to include("voided or credited")
    end

    it "defaults to the latest three months before today, or the earliest, when the year doesn't cover today" do
      code
      travel_to Time.zone.local(2027, 2, 10, 9)
      get routes.reports_supplier_certificates_path
      expect(css_select("#quarter option[selected]").map { |option| option["value"] }).to eq([ "2026-10-01" ])
      travel_to Time.zone.local(2025, 2, 10, 9)
      get routes.reports_supplier_certificates_path
      expect(css_select("#quarter option[selected]").map { |option| option["value"] }).to eq([ "2026-01-01" ])
    end

    it "downloads all the certificates, or one supplier's, and hides the links without PDFs" do
      bill(ledger, Date.new(2026, 4, 10), 10_000_00)
      bill(aurora, Date.new(2026, 5, 10), 5_000_00)
      TudlaAccounting.configuration.withholding_agent = ->(org) { { name: org.name, tin: "000-111-222-00000", address: "1 Demo Street, Makati City", zip: "1223", signatory_name: "Maria Santos", signatory_title: "Finance Manager", signatory_tin: "000-333-444-000" } }

      get routes.reports_supplier_certificates_path(format: :pdf)
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("BIR-2307-all-suppliers-2026-04-01-to-2026-06-30.pdf")
      expect(PDF::Reader.new(StringIO.new(response.body)).page_count).to eq(2)

      get routes.reports_supplier_certificates_path(format: :pdf, contact_id: ledger.id)
      expect(response.headers["Content-Disposition"]).to include("BIR-2307-Ledger-Co-2026-04-01-to-2026-06-30.pdf")
      expect(PDF::Reader.new(StringIO.new(response.body)).page_count).to eq(1)

      get routes.reports_supplier_certificates_path(format: :pdf, quarter: "2026-01-01", contact_id: ledger.id)
      expect(response).to have_http_status(:not_found)

      allow(TudlaAccounting::PdfMaker).to receive(:from_html).and_raise(TudlaAccounting::PdfMaker::Error, "The PDF couldn't be made (Chrome went away)")
      get routes.reports_supplier_certificates_path(format: :pdf)
      expect(response).to redirect_to(routes.reports_supplier_certificates_path(quarter: "2026-04-01"))
      allow(TudlaAccounting::PdfMaker).to receive(:from_html).and_call_original

      allow(TudlaAccounting).to receive(:pdf?).and_return(false)
      get routes.reports_supplier_certificates_path
      expect(response.body).not_to include("All as PDF")
      expect(css_select("[data-certificate-row] a").map { |link| link.text }).not_to include("PDF")
      get routes.reports_supplier_certificates_path(format: :pdf)
      expect(response).to have_http_status(:not_found)
    end
  end
end
