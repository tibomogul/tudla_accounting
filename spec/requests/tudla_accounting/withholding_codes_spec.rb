require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Withholding codes", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, currency: "PHP") }

  before do
    sign_in_as(organization)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "1200", name: "Creditable tax", category: "asset" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2300", name: "Withholding payable", category: "liability" }, { code: "4000", name: "Sales", category: "income" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def rows = css_select("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
  def code(text = "WC010") = TudlaAccounting::WithholdingCode.find_by!(organization: organization, code: text)

  it "is linked from setup, and invites adding the first code" do
    get routes.setup_path
    expect(css_select("a").map { |link| link["href"] }).to include(routes.withholding_codes_path)
    get routes.withholding_codes_path
    expect(response.body).to include("No withholding codes yet.")
    expect(css_select("#payable_account_id option").map(&:text)).to eq([ "None", "2300 - Withholding payable" ])
    expect(css_select("#creditable_account_id option").map(&:text)).to eq([ "None", "1200 - Creditable tax" ])
  end

  it "adds, lists, edits and deletes codes, recording them on the activity log" do
    get routes.new_withholding_code_path
    expect(css_select("#withholding_code_payable_account_id option").map(&:text)).to eq([ "None", "2300 - Withholding payable" ])

    post routes.withholding_codes_path, params: { withholding_code: { code: "wc010", name: "Professionals", rate_percent: "10", payable_account_id: account("2300").id, creditable_account_id: "", active: "1" } }
    expect(response).to redirect_to(routes.withholding_codes_path)
    expect(flash[:notice]).to eq("Withholding code WC010 (10%) was added.")
    get routes.withholding_codes_path
    expect(rows).to eq([ [ "WC010", "Professionals", "10%", "2300 - Withholding payable", "None", "" ] ])

    get routes.edit_withholding_code_path(code)
    expect(css_select("form[data-controller=confirm]").size).to eq(1)
    patch routes.withholding_code_path(code), params: { withholding_code: { rate_percent: "15", creditable_account_id: account("1200").id, active: "0" } }
    expect(flash[:notice]).to eq("Withholding code WC010 (15%) was saved.")
    get routes.withholding_codes_path
    expect(rows).to eq([ [ "WC010", "Professionals", "15%", "2300 - Withholding payable", "1200 - Creditable tax", "Inactive" ] ])

    get routes.activity_path(kind: "withholding_code")
    expect(css_select("tbody td:last-child").map { |cell| cell.text.squish }).to eq([ "Changed WC010 (15%): rate, active, creditable account", "Added the withholding code WC010 (10%)" ])
    expect(css_select("tbody a").map { |link| link["href"] }).to include(routes.edit_withholding_code_path(code))

    delete routes.withholding_code_path(code)
    expect(flash[:notice]).to eq("Withholding code WC010 was deleted.")
    get routes.activity_path(kind: "withholding_code")
    expect(css_select("tbody td:last-child").first.text.squish).to eq("Deleted the withholding code WC010 (15%)")
  end

  it "shows what is wrong with a code, and keeps one in use" do
    post routes.withholding_codes_path, params: { withholding_code: { code: "", name: "", rate_percent: "abc", payable_account_id: "", creditable_account_id: "" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("abc isn&#39;t a number", "Choose an account")

    made = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC010", name: "Professionals", rate: "0.1", payable_account: account("2300"))
    patch routes.withholding_code_path(made), params: { withholding_code: { rate_percent: "200" } }
    expect(response).to have_http_status(:unprocessable_entity)

    TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier", default_withholding_code: made)
    get routes.edit_withholding_code_path(made)
    expect(response.body).to include("This code is in use")
    expect(css_select("form[data-controller=confirm]")).to be_empty
    delete routes.withholding_code_path(made)
    expect(flash[:alert]).to eq("Bills, payments or contacts use WC010; make it inactive instead")
  end

  it "adds a starter list, once, and says when it can't" do
    post routes.add_template_withholding_codes_path, params: { template: "ph_expanded", payable_account_id: "", creditable_account_id: "" }
    expect(flash[:alert]).to include("Choose an account")

    post routes.add_template_withholding_codes_path, params: { template: "ph_expanded", payable_account_id: account("2300").id, creditable_account_id: account("1200").id }
    expect(flash[:notice]).to eq("20 withholding codes added. Check their rates before relying on them.")
    expect(code("WI160")).to have_attributes(payable_account: account("2300"), creditable_account: account("1200"))

    post routes.add_template_withholding_codes_path, params: { template: "ph_expanded", payable_account_id: account("2300").id }
    expect(flash[:notice]).to eq("You have all of that list's codes already.")
  end

  it "belongs to those who administer, and only to the organization" do
    other = create(:organization, currency: "PHP")
    TudlaAccounting::AccountsCreator.call([ { code: "2300", name: "Theirs", category: "liability" } ], other)
    theirs = TudlaAccounting::WithholdingCode.create!(organization: other, code: "WC010", name: "Theirs", rate: "0.1", payable_account: TudlaAccounting::Account.find_by!(organization: other))
    get routes.edit_withholding_code_path(theirs)
    expect(response).to have_http_status(:not_found)

    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permission != :administer }
    get routes.withholding_codes_path
    expect(response).not_to have_http_status(:ok)
  end
end
