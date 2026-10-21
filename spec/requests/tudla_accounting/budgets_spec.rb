require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Budgets", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record] }

  before do
    travel_to Time.zone.local(2026, 3, 15, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    @last_year = TudlaAccounting::PeriodCreator.call(organization, 2025)
    @year = TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "4000", name: "Sales", category: "income" }, { code: "6100", name: "Rent", category: "expense" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def month(number, year = @year) = year.children.order(:from_date).to_a[number - 1]
  def budget(name = "Original") = TudlaAccounting::Budget.find_by!(organization: organization, name: name)
  def cells(code) = css_select("tr[data-account-row='#{code}'] td").map { |cell| cell.at_css("input")&.[]("value") || cell.text.squish }

  it "adds a blank budget, enters its amounts and shows them" do
    get routes.budgets_path
    expect(response.body).to include("None yet.")
    get routes.new_budget_path
    expect(css_select("select[name='budget[period_id]'] option[selected]").map(&:text)).to eq([ "2026" ]) # next year has no period
    expect(css_select("input[name='budget[main]'][type=checkbox][checked]")).not_to be_empty

    post routes.budgets_path, params: { budget: { name: "Original", period_id: @year.id, main: "1" }, start: "blank" }
    expect(response).to redirect_to(routes.edit_budget_path(budget))
    get routes.edit_budget_path(budget)
    expect(css_select("input[name='amounts[#{account('4000').id}][#{month(1).id}]']")).not_to be_empty
    expect(response.body).not_to include("1000 - Bank")

    patch routes.budget_path(budget), params: { budget: { name: "Original", main: "1" },
                                                amounts: { account("4000").id => { month(1).id => "1,000", month(2).id => "" }, account("6100").id => { month(1).id => "400" } } }
    expect(response).to redirect_to(routes.budget_path(budget))
    expect(budget.amounts).to eq(account("4000").id => { month(1).id => 1_000_00 }, account("6100").id => { month(1).id => 400_00 })

    get routes.budget_path(budget)
    expect(cells("4000").first(3)).to eq([ "4000Sales", "1,000.00", "" ])
    expect(css_select("[data-total=net_profit] td").map { |cell| cell.text.squish }.values_at(1, -1)).to eq([ "600.00", "600.00" ])
    get routes.budgets_path
    expect(css_select("tr[data-budget] td").map { |cell| cell.text.squish }).to eq([ "2026", "Original Main", "1,000.00", "400.00", "600.00", "15 Mar 2026" ])
    get routes.activity_path(kind: "budget")
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish }).to eq([ "Changed the amounts of 4000, 6100 in the budget Original (2026)", "Added the budget Original (2026)" ])
  end

  it "shows what was typed when it can't be saved" do
    post routes.budgets_path, params: { budget: { name: "Original", period_id: @year.id }, start: "blank" }
    patch routes.budget_path(budget), params: { budget: { name: "Original" }, amounts: { account("4000").id => { month(1).id => "lots", month(2).id => "5" } } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("4000 - Sales, Jan 2026: lots isn&#39;t an amount")
    expect(cells("4000")[1..2]).to eq(%w[lots 5])

    patch routes.budget_path(budget), params: { budget: { name: "" }, amounts: { account("4000").id => { month(1).id => "5" } } }
    expect(response.body).to include("Name can&#39;t be blank")
    patch routes.budget_path(budget), params: { budget: { name: "Original" }, amounts: { account("1000").id => { month(1).id => "5" } } }
    expect(response.body).to include("Only the organization&#39;s income and expense accounts can have a budget")
    expect(budget.amounts).to be_empty
  end

  it "starts from a year's actual results or another budget, and says what is wrong" do
    entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Sale",
                                                         transacted_at: "2025-02-10T00:00:00Z", details: [ { account_code: "4000", amount: "AUD 1000" }, { account_code: "1000", amount: "AUD 1000" } ])
    entry.post(entry.transacted_at)
    post routes.budgets_path, params: { budget: { name: "Original", period_id: @year.id }, start: "actuals", actuals_period_id: @last_year.id, percent: "+5%" }
    expect(budget.amounts).to eq(account("4000").id => { month(2).id => 1_050_00 })

    post routes.budgets_path, params: { budget: { name: "Copy", period_id: @last_year.id }, start: "budget", budget_id: budget.id }
    expect(budget("Copy").amounts).to eq(account("4000").id => { month(2, @last_year).id => 1_050_00 })

    post routes.budgets_path, params: { budget: { name: "Bad", period_id: @year.id }, start: "actuals", actuals_period_id: @last_year.id, percent: "lots" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("lots isn&#39;t a percentage")
    post routes.budgets_path, params: { budget: { name: "Original", period_id: @year.id }, start: "blank" }
    expect(response.body).to include("Name has already been taken")
    expect(TudlaAccounting::Budget.where(organization: organization).count).to eq(2)
  end

  it "downloads, uploads and deletes one" do
    post routes.budgets_path, params: { budget: { name: "Original", period_id: @year.id }, start: "blank" }
    budget.set_amounts!(account("6100").id => { month(1).id => 400_00 })

    get routes.budget_path(budget, format: :csv)
    expect(response.headers["Content-Disposition"]).to include("budget-2026-original.csv")
    csv = CSV.parse(response.body)
    expect(csv[0].first(4)).to eq([ "Section", "Code", "Account", "Jan 2026" ])
    get routes.budget_path(budget, format: :xlsx)
    expect(response.media_type).to eq(Mime[:xlsx].to_s)

    csv[csv.index { |row| row[1] == "4000" }][4] = "250"
    upload = Rack::Test::UploadedFile.new(StringIO.new(CSV.generate { |out| csv.each { |row| out << row } }), "text/csv", original_filename: "budget.csv")
    post routes.upload_budget_path(budget), params: { file: upload }
    expect(flash[:notice]).to eq("Amounts for 2 accounts read from budget.csv.")
    expect(budget.amounts).to eq(account("6100").id => { month(1).id => 400_00 }, account("4000").id => { month(2).id => 250_00 })

    post routes.upload_budget_path(budget), params: { file: Rack::Test::UploadedFile.new(StringIO.new("Code\n"), "text/plain", original_filename: "budget.txt") }
    expect(flash[:alert]).to eq("The file was not read: upload a .csv or .xlsx file.")
    post routes.upload_budget_path(budget)
    expect(flash[:alert]).to start_with("The file was not read: ")

    patch routes.budget_path(budget), params: { budget: { name: "Original", main: "1" } }
    delete routes.budget_path(budget)
    expect(flash[:notice]).to eq("Budget Original (2026) deleted.")
    expect(TudlaAccounting::BudgetLine.count).to eq(0)
    get routes.activity_path(kind: "budget")
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish }.first(2)).to eq([ "Deleted the budget Original (2026)", "Changed the budget Original (2026): main" ])
  end

  it "has no Excel download without caxlsx" do
    post routes.budgets_path, params: { budget: { name: "Original", period_id: @year.id }, start: "blank" }
    allow(TudlaAccounting).to receive(:xlsx?).and_return(false)
    get routes.budget_path(budget, format: :xlsx)
    expect(response).to have_http_status(:not_found)
  end

  context "when allowed only to read" do
    let(:permissions) { %i[read] }

    it "shows budgets but doesn't change them" do
      plan = TudlaAccounting::Budget.create!(organization: organization, period: @year, name: "Original")
      get routes.budget_path(plan)
      expect(response.body).not_to include("Edit amounts", "Upload amounts")
      get routes.budgets_path
      expect(response.body).not_to include("New budget")
      patch routes.budget_path(plan), params: { budget: { name: "x" } }
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "asks for a year first, and keeps other organizations' to themselves" do
    other = create(:organization, currency: "AUD")
    theirs = TudlaAccounting::Budget.create!(organization: other, period: TudlaAccounting::PeriodCreator.call(other, 2026), name: "Theirs")
    get routes.budget_path(theirs)
    expect(response).to have_http_status(:not_found)

    sign_in_as(create(:organization, currency: "AUD"))
    get routes.budgets_path
    expect(response.body).to include("Create a financial year")
  end
end
