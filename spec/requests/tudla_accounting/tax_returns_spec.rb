require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Tax returns", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post administer] }

  before do
    travel_to Time.zone.local(2026, 3, 20, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    @year = TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }, { code: "6040", name: "Wages", category: "expense" }
    ], organization)
    @gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST on sales", rate: "0.1", kind: :sales, account: account("2200"))
    entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Sale", transacted_at: "2026-03-10T00:00:00Z",
                                                         details: [ { account_code: "1100", amount: "AUD 1100.00" }, { account_code: "4000", amount: "AUD 1000.00", tax_code: "GST" } ])
    entry.post(entry.transacted_at)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def form(name = "BAS") = TudlaAccounting::TaxReturnForm.find_by!(organization: organization, name: name)
  def box(label) = form.boxes.find_by!(label: label)
  def return_rows = css_select("table[data-tax-return] tbody").map { |body| body.css("tr").map { |row| row.css("td").map { |cell| cell.text.squish } } }

  it "sets up a BAS from its template, maps a box, and shows the return for the months" do
    get routes.tax_return_forms_path
    expect(response.body).to include("None yet.")
    get routes.new_tax_return_form_path
    expect(css_select("select[name=template] option").map(&:text)).to include("Australia: Business activity statement (GST and PAYG withholding)")

    post routes.tax_return_forms_path, params: { template: "au_bas", tax_return_form: { name: "" } }
    expect(response).to redirect_to(routes.tax_return_form_path(form))
    expect(flash[:notice]).to eq("Tax return BAS added. Add the tax codes and accounts that fill its boxes.")
    get routes.tax_return_form_path(form)
    expect(css_select("tr[data-box] td:first-child").map { |cell| cell.text.squish }).to eq(%w[G1 G2 G3 G10 G11 1A 1B W1 W2] + [ "Net GST" ])
    expect(css_select("tr[data-box='Net GST'] td")[2].css("div").map(&:text)).to eq([ "The box 1A", "less The box 1B" ])

    get routes.edit_tax_return_form_box_path(form, box("1A"))
    expect(css_select("tr[data-part]").size).to eq(3)
    expect(css_select("select[name$='[from_box_id]'] option").map(&:text)).not_to include("1A GST on sales")
    patch routes.tax_return_form_box_path(form, box("1A")), params: { tax_return_box: { label: "1A", name: "GST on sales", position: "60", whole_units: "1",
                                                                                         parts_attributes: { "0" => { source: "tax_code_tax", sign: "1", tax_code_id: @gst.id },
                                                                                                             "1" => { source: "", sign: "1" } } } }
    expect(response).to redirect_to(routes.tax_return_form_path(form))
    patch routes.tax_return_form_box_path(form, box("G1")), params: { tax_return_box: { label: "G1", name: "Total sales", position: "10", whole_units: "1",
                                                                                         parts_attributes: { "0" => { source: "tax_code_gross", sign: "1", tax_code_id: @gst.id } } } }

    get routes.reports_tax_return_path
    expect(css_select("select[name=form_id] option[selected]").map(&:text)).to eq([ "BAS" ])
    rows = return_rows
    expect(rows.first).to eq([ [ "G1", "Total sales", "1,100.00" ], [ "", "Gross amount taxed under GST", "1,100.00" ] ])
    expect(rows.find { |body| body.first.first == "1A" }.first).to eq([ "1A", "GST on sales", "100.00" ])
    expect(rows.find { |body| body.first.first == "G2" }.last.last).to eq("Nothing fills this box yet: add its tax codes or accounts.")

    get routes.reports_tax_return_path(format: :csv)
    expect(response.headers["Content-Disposition"]).to include("bas-accrual-2026-03-01-to-2026-03-31.csv")
    expect(CSV.parse(response.body).first(2)).to eq([ %w[Box Name Amount], [ "G1", "Total sales", "1100.00" ] ])

    get routes.reports_tax_path
    expect(css_select("a").map { |link| link["href"] }).to include(routes.reports_tax_return_path(form_id: form.id, from_id: @year.children.order(:from_date).third.id,
                                                                                                  thru_id: @year.children.order(:from_date).third.id, basis: "accrual"))
    get routes.activity_path(kind: "tax_return_form")
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish }.first(2)).to eq([ "Changed the box G1 of the tax return BAS", "Changed the box 1A of the tax return BAS" ])
  end

  it "adds, refuses, renames and deletes boxes and forms" do
    post routes.tax_return_forms_path, params: { tax_return_form: { name: "Annual" } }
    expect(flash[:notice]).to eq("Tax return Annual added.")
    post routes.tax_return_forms_path, params: { tax_return_form: { name: "Annual" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Name has already been taken")

    get routes.new_tax_return_form_box_path(form("Annual"))
    expect(css_select("input[name='tax_return_box[position]']").first["value"]).to eq("10")
    post routes.tax_return_form_boxes_path(form("Annual")), params: { tax_return_box: { label: "W1", name: "Wages", position: "10",
                                                                                         parts_attributes: { "0" => { source: "account", sign: "1", account_id: account("6040").id } } } }
    first = form("Annual").boxes.find_by!(label: "W1")
    get routes.tax_return_form_path(form("Annual"))
    expect(css_select("tr[data-box='W1'] td")[2].text.squish).to eq("Movement in the account 6040 - Wages")
    post routes.tax_return_form_boxes_path(form("Annual")), params: { tax_return_box: { label: "Up", name: "Above", position: "5",
                                                                                         parts_attributes: { "0" => { source: "box", sign: "1", from_box_id: first.id } } } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("W1 must be a box above this one on the form")
    expect(css_select("tr[data-part]").size).to eq(3)
    post routes.tax_return_form_boxes_path(form("Annual")), params: { tax_return_box: { label: "Total", name: "Total", position: "20",
                                                                                         parts_attributes: { "0" => { source: "box", sign: "-1", from_box_id: first.id } } } }
    delete routes.tax_return_form_box_path(form("Annual"), first)
    expect(flash[:alert]).to eq("Total uses W1; change it first")
    total = form("Annual").boxes.find_by!(label: "Total")
    patch routes.tax_return_form_box_path(form("Annual"), total), params: { tax_return_box: { label: "Total", name: "Total", position: "20",
                                                                                               parts_attributes: { "0" => { id: total.parts.first.id, _destroy: "1" } } } }
    delete routes.tax_return_form_box_path(form("Annual"), first)
    expect(flash[:notice]).to eq("Box W1 deleted.")

    get routes.edit_tax_return_form_path(form("Annual"))
    patch routes.tax_return_form_path(form("Annual")), params: { tax_return_form: { name: "" } }
    expect(response).to have_http_status(:unprocessable_entity)
    patch routes.tax_return_form_path(form("Annual")), params: { tax_return_form: { name: "Yearly" } }
    expect(response).to redirect_to(routes.tax_return_form_path(form("Yearly")))
    get routes.tax_return_forms_path
    expect(css_select("tr[data-tax-return-form] td").map { |cell| cell.text.squish }.first(2)).to eq([ "Yearly", "1" ])
    delete routes.tax_return_form_path(form("Yearly"))
    expect(flash[:notice]).to eq("Tax return Yearly deleted.")
    get routes.activity_path(kind: "tax_return_form")
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish }.first(2)).to eq([ "Deleted the tax return Yearly", "Changed the tax return Yearly: name" ])
  end

  it "asks for a return to be set up first" do
    get routes.reports_tax_return_path
    expect(response.body).to include("No tax returns set up yet.")
    get routes.reports_tax_path
    expect(response.body).to include("Set up a tax return")
  end

  context "when allowed to read but not administer" do
    let(:permissions) { %i[read record post] }

    it "shows the return but not its setup" do
      TudlaAccounting::TaxReturnForm.from_template!(organization, "uk_vat")
      get routes.reports_tax_return_path
      expect(response.body).not_to include("add its tax codes", "Change the boxes")
      get routes.tax_return_forms_path
      expect(response).to have_http_status(:forbidden)
    end
  end
end
