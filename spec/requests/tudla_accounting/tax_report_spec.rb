require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "Tax summary", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, currency: "AUD") }

  before { sign_in_as(organization) }

  def total(name) = css_select("[data-total=#{name}]").first&.text&.squish
  def month(number) = year.children.order(:from_date)[number - 1]

  it "asks for a financial year first, and is listed with the reports" do
    get routes.reports_tax_path
    expect(response.body).to include("No financial year yet.")
    get routes.reports_path
    expect(response.body).to include("Tax summary")
  end

  context "with a year" do
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

    before do
      TudlaAccounting::AccountsCreator.call([
        { code: "1100", name: "Receivables", category: "asset" }, { code: "2100", name: "Payables", category: "liability" },
        { code: "2200", name: "GST", category: "liability" }, { code: "4000", name: "Sales", category: "income" },
        { code: "6000", name: "Supplies", category: "expense" }
      ], organization)
    end

    it "points to setting up tax codes when there are none" do
      get routes.reports_tax_path
      expect(response.body).to include("No tax codes yet.", routes.tax_codes_path)
    end

    context "with taxed entries" do
      before do
        gst = TudlaAccounting::Account.find_by(organization: organization, code: "2200")
        TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST on sales", rate: "0.1", kind: :sales, account: gst)
        TudlaAccounting::TaxCode.create!(organization: organization, code: "GSTP", name: "GST on purchases", rate: "0.1", kind: :purchases, account: gst)
        [ [ "2026-02-03", [ { account_code: "1100", amount: "AUD 110.00" }, { account_code: "4000", amount: "AUD 100.00", tax_code: "GST" } ] ],
          [ "2026-03-04", [ { account_code: "6000", amount: "AUD 330.00", tax_code: "GSTP" }, { account_code: "2100", amount: "AUD 330.00" } ] ] ].each do |on, details|
          entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Entry",
                                                               transacted_at: "#{on}T00:00:00Z", details: details, tax_inclusive: on.start_with?("2026-03"))
          entry.post(entry.transacted_at)
        end
      end

      it "shows the month containing today by default" do
        travel_to(Time.zone.local(2026, 2, 15)) { get routes.reports_tax_path }
        expect([ total("sales_base"), total("sales_tax"), total("purchases_tax"), total("net_tax") ]).to eq([ "100.00", "10.00", "0.00", "10.00" ])
        expect(response.body).to include("Owed to the tax authority", "1 Feb 2026 to 28 Feb 2026")
      end

      it "covers a chosen run of months, either way round, with a refund when more was paid" do
        get routes.reports_tax_path(from_id: month(3).id, thru_id: month(2).id)
        expect(response.body).to include("1 Feb 2026 to 31 Mar 2026")
        expect([ total("sales_tax"), total("purchases_base"), total("purchases_tax"), total("net_tax") ]).to eq([ "10.00", "300.00", "30.00", "20.00" ])
        expect(response.body).to include("Refund due")
        expect(css_select("#from_id option[selected]").text).to eq("Feb 2026")
      end

      it "refuses another organization's month" do
        get routes.reports_tax_path(from_id: TudlaAccounting::PeriodCreator.call(create(:organization), 2026).children.first.id)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
