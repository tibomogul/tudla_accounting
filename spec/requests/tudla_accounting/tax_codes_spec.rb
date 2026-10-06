require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "Tax codes", type: :request do
  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    sign_in_as(organization)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def rows = css_select("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
  def gst = TudlaAccounting::TaxCode.find_by!(organization: organization, code: "GST")

  it "invites adding the first code" do
    get routes.tax_codes_path
    expect(response.body).to include("No tax codes yet.")
  end

  it "adds, lists and edits codes, recording them on the activity log" do
    get routes.new_tax_code_path(kind: "purchases")
    expect(css_select("#tax_code_kind option[selected]").text).to eq("Purchases (tax paid)")

    post routes.tax_codes_path, params: { tax_code: { code: "GST", name: "GST on sales", kind: "sales", rate_percent: "10", account_id: account("2200").id, active: "1" } }
    expect(response).to redirect_to(routes.tax_codes_path)
    expect(flash[:notice]).to eq("Tax code GST (10%) was added.")
    expect(gst).to have_attributes(rate: BigDecimal("0.1"), account: account("2200"), kind: "sales")

    post routes.tax_codes_path, params: { tax_code: { code: "FRE", name: "GST-free", kind: "sales", rate_percent: "0", account_id: "", active: "0" } }
    get routes.tax_codes_path
    expect(rows).to eq([ [ "FRE", "GST-free", "Sales (collected)", "0%", "None", "Inactive" ], [ "GST", "GST on sales", "Sales (collected)", "10%", "2200 - GST", "" ] ])

    patch routes.tax_code_path(gst), params: { tax_code: { rate_percent: "12.5" } }
    expect(flash[:notice]).to eq("Tax code GST (12.5%) was saved.")
    get routes.activity_path(kind: "tax_code")
    expect(css_select("tbody td:last-child").map { |cell| cell.text.squish })
      .to eq([ "Changed GST (12.5%): rate", "Added the tax code FRE (0%)", "Added the tax code GST (10%)" ])
    expect(css_select("tbody a").map { |link| link["href"] }).to include(routes.edit_tax_code_path(gst))
  end

  it "shows what is wrong with a code" do
    post routes.tax_codes_path, params: { tax_code: { code: "", name: "GST", kind: "sales", rate_percent: "ten", account_id: "" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(css_select("[role=alert]").text).to include("Rate ten isn't a number", "Rate is not a number")
    expect(response.body).to include("Code can&#39;t be blank")

    post routes.tax_codes_path, params: { tax_code: { code: "GST", name: "GST", kind: "sales", rate_percent: "10", account_id: "" } }
    expect(css_select("[role=alert]").text).to include("Account is needed for a code with a rate")
  end

  context "with a code in use" do
    before do
      TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST on sales", rate: "0.1", kind: :sales, account: account("2200"))
      entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Invoice",
                                                           transacted_at: "2026-02-01T00:00:00Z",
                                                           details: [ { account_code: "1100", amount: "AUD 110.00" }, { account_code: "4000", amount: "AUD 100.00", tax_code: "GST" } ])
      entry.post(entry.transacted_at)
    end

    it "keeps it, and what it is for, but lets it be made inactive" do
      get routes.edit_tax_code_path(gst)
      expect(response.body).to include("Lines are taxed under this code")
      expect(css_select("#tax_code_kind[disabled]")).to be_present
      expect(response.body).not_to include(">Delete<")

      patch routes.tax_code_path(gst), params: { tax_code: { kind: "purchases" } }
      expect(css_select("[role=alert]").text).to include("Kind can't change once lines are taxed under it; add a new code instead")

      delete routes.tax_code_path(gst)
      expect(flash[:alert]).to eq("Lines are taxed under GST; make it inactive instead")
      expect(gst).to be_present

      patch routes.tax_code_path(gst), params: { tax_code: { active: "0" } }
      get routes.tax_codes_path
      expect(rows.first.last).to eq("Inactive In use")
    end
  end

  it "deletes an unused code, and refuses another organization's" do
    TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200"))
    get routes.edit_tax_code_path(gst)
    expect(response.body).to include(">Delete<")
    delete routes.tax_code_path(gst)
    expect(flash[:notice]).to eq("Tax code GST was deleted.")
    get routes.activity_path
    expect(css_select("tbody td:last-child").first.text.squish).to eq("Deleted the tax code GST (10%)")

    other = create(:organization)
    code = TudlaAccounting::TaxCode.create!(organization: other, code: "VAT", name: "VAT", rate: 0, kind: :sales)
    get routes.edit_tax_code_path(code)
    expect(response).to have_http_status(:not_found)
  end
end
