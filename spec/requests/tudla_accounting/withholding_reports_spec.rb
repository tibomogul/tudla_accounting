require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Withholding reports", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }
  let(:code) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Contractors", rate: "0.02", payable_account: account("2300"), creditable_account: account("1200")) }
  let(:supplier) { TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier") }
  let(:customer) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer", tax_number: "111-222-333-000") }

  before do
    travel_to Time.zone.local(2026, 5, 25, 9)
    sign_in_as(organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def text(selector) = css_select(selector).map { |node| node.text.squish }
  def cells(selector) = css_select(selector).map { |row| row.css("td").map { |cell| cell.text.squish }.join(" ") }
  def month(number) = TudlaAccounting::Period.leaf_periods_for_date(organization, Time.zone.local(2026, number, 15, 12)).first

  context "without a financial year" do
    it "says so, and has nothing to download" do
      [ routes.reports_withholding_path, routes.reports_qap_path, routes.reports_sawt_path ].each do |path|
        get path
        expect(response.body).to include("to see reports.")
        get "#{path}.csv"
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  context "with a financial year" do
    before do
      TudlaAccounting::PeriodCreator.call(organization, 2026)
      TudlaAccounting::AccountsCreator.call([
        { code: "1010", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "1200", name: "Creditable tax", category: "asset" },
        { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2300", name: "Withholding payable", category: "liability" }, { code: "6000", name: "Fees", category: "expense" }
      ], organization)
    end

    def activity
      TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 4, 10),
                                        lines_attributes: [ { description: "Work", unit_price_cents: 10_000_00, account: account("6000"), withholding_code: code } ]).approve!
      marked = TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: customer, account: account("1010"), paid_on: Date.new(2026, 4, 20), amount_cents: 9_800_00, withholdings: [ { code: code, withheld_cents: 200_00 } ])
      TudlaAccounting::WithheldTax.find_by!(payment: marked).mark_certificate!(on: Date.new(2026, 5, 5))
      TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: customer, account: account("1010"), paid_on: Date.new(2026, 5, 20), amount_cents: 4_900_00, withholdings: [ { code: code, withheld_cents: 100_00 } ])
    end

    it "offers the reports once there's a code, and asks for codes without one" do
      get routes.reports_path
      expect(text("a .font-semibold")).not_to include("Withholding summary")
      [ routes.reports_withholding_path, routes.reports_qap_path, routes.reports_sawt_path ].each do |path|
        get path
        expect(response.body).to include("No withholding codes yet.")
      end
      code
      get routes.reports_path
      expect(text("a .font-semibold")).to include("Withholding summary", "Tax withheld from suppliers (QAP)", "Tax withheld from you (SAWT)")
    end

    it "shows the summary for this quarter by default, with the accounts beside it" do
      activity
      get routes.reports_withholding_path
      expect(css_select("#from_id option[selected]").first.text).to include("Apr 2026")
      expect(css_select("#thru_id option[selected]").first.text).to include("Jun 2026")
      expect(cells("[data-withholding-summary=from_supplier] tbody tr").first).to eq("WC120 Contractors 2% 200.00 0.00 0.00 10,000.00 200.00")
      expect(text("[data-total=by_customer]")).to eq([ "300.00" ])
      expect(cells("[data-withholding-check=from_supplier] tbody tr")).to eq([ "2300 - Withholding payable 200.00 200.00 0.00" ])

      get routes.reports_withholding_path(from_id: month(1).id, thru_id: month(3).id)
      expect(text("[data-withholding-summary] p")).to eq([ "Nothing in these months.", "Nothing in these months." ])
    end

    it "shows the QAP, flagging a missing TIN, and downloads it" do
      activity
      get routes.reports_qap_path
      expect(text("h1")).to eq([ "Tax withheld from suppliers (QAP)" ])
      expect(text("[data-missing-tin]")).to eq([ "No TIN for Ledger & Co. Add it on the contact before filing." ])
      expect(cells("[data-withholding-row]")).to eq([ "No TIN Ledger & Co WC120 2% 10,000.00 200.00" ])
      expect(response.body).not_to include("data-not-listed")

      get routes.reports_qap_path(format: :csv, from_id: month(4).id, thru_id: month(6).id)
      expect(response.headers["Content-Disposition"]).to include("qap-2026-04-01-to-2026-06-30.csv")
      expect(response.body).to include("Ledger & Co,WC120,2.0,10000.00,200.00,No TIN")
      get routes.reports_qap_path(format: :xlsx)
      expect(response.media_type).to eq(Mime[:xlsx].to_s)
    end

    it "shows the SAWT, marked certificates only, with the rest beside it" do
      activity
      get routes.reports_sawt_path
      expect(text("h1")).to eq([ "Tax withheld from you (SAWT)" ])
      expect(cells("[data-withholding-row]")).to eq([ "111-222-333-000 Northwind WC120 2% 10,000.00 200.00" ])
      expect(text("[data-total=list]")).to eq([ "200.00" ])
      expect(text("[data-waiting]")).to eq([ "100.00" ])
      expect(css_select("[data-reversed]")).to be_empty
      expect(css_select("[data-missing-tin]")).to be_empty
      expect(css_select("[data-not-listed] a").first["href"]).to eq(routes.withholding_certificates_path)
      expect(cells("[data-withholding-check=by_customer] tbody tr")).to eq([ "1200 - Creditable tax 300.00 300.00 0.00" ])

      get routes.reports_sawt_path(from_id: month(1).id, thru_id: month(3).id)
      expect(response.body).to include("No certificates marked received for these months.")
    end

    it "shows what was reversed since, on the SAWT" do
      code
      paid = TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: customer, account: account("1010"), paid_on: Date.new(2026, 4, 20), amount_cents: 9_800_00, withholdings: [ { code: code, withheld_cents: 200_00 } ])
      paid.void!(on: Date.new(2026, 7, 2), reason: "Bounced")
      get routes.reports_sawt_path
      expect(text("[data-reversed]")).to eq([ "200.00" ])
    end
  end
end
