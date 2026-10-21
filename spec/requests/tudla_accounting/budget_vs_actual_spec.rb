require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "Budget vs actual", type: :request do
  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let!(:last_year) { TudlaAccounting::PeriodCreator.call(organization, 2025) }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let!(:budget) { TudlaAccounting::Budget.create!(organization: organization, period: year, name: "Original", main: true) }

  before do
    sign_in_as(organization)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash", category: "asset" }, { code: "4000", name: "Sales", category: "income" },
      { code: "4100", name: "Interest", category: "income" }, { code: "6000", name: "Rent", category: "expense" }
    ], organization)
    post_entry(2, "1010", "4000", 100)
    post_entry(3, "1010", "4000", 120)
    post_entry(3, "6000", "1010", 30)
    post_entry(2, "1010", "4100", 5)
    budget.set_amounts!(account("4000").id => { month(2).id => 90_00, month(3).id => 100_00 }, account("6000").id => { month(3).id => 40_00 })
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def month(number, period = year) = period.children.order(:from_date).to_a[number - 1]

  def post_entry(month_number, debit, credit, amount)
    at = Time.zone.local(2026, month_number, 10)
    record = build(:tudla_accounting_entry, organization: organization, particulars: "Entry", transacted_at: at)
    record.details.build(account: account(debit), tally: :debit, amount_cents: amount * 100, currency: "AUD", organization: organization)
    record.details.build(account: account(credit), tally: :credit, amount_cents: amount * 100, currency: "AUD", organization: organization)
    record.save!
    record.post(at)
  end

  def headings = css_select("table[data-comparison] thead tr").map { |row| row.css("th").map { |cell| cell.text.squish } }
  def section(category) = css_select("table[data-comparison] tbody[data-section='#{category}'] tr").reject { |row| row.css("td").empty? }.map { |row| row.css("td").map { |cell| cell.text.squish } }

  it "puts a month beside its budget, then the year to date, marking variances favourable or not" do
    get routes.reports_profit_and_loss_path(period_id: month(3).id, compare: "budget")

    expect(headings).to eq([ [ "", "Mar 2026", "Year to date" ], [ "Account", *[ "Actual", "Budget", "Variance", "%" ] * 2 ] ])
    expect(section("income")).to eq([
      [ "4000Sales", "120.00", "100.00", "20.00 F", "20.0%", "220.00", "190.00", "30.00 F", "15.8%" ],
      [ "4100Interest", "0.00", "0.00", "0.00", "—", "5.00", "0.00", "5.00 F", "—" ], # nothing this month, nor budgeted
      [ "Total income", "120.00", "100.00", "20.00 F", "20.0%", "225.00", "190.00", "35.00 F", "18.4%" ]
    ])
    expect(section("expense").first).to eq([ "6000Rent", "30.00", "40.00", "(10.00) F", "-25.0%", "30.00", "40.00", "(10.00) F", "-25.0%" ])
    expect(section("figures")).to eq([ [ "Net profit (loss)", "90.00", "60.00", "30.00 F", "50.0%", "195.00", "150.00", "45.00 F", "30.0%" ] ])
    expect(css_select("select[name=compare] option[selected]").map(&:text)).to eq([ "Budget: Original" ])
    expect(css_select("a[href='#{routes.budget_path(budget)}']").map(&:text)).to eq([ "Original (2026)" ])
  end

  it "compares a year with another of its budgets, unfavourably" do
    revised = TudlaAccounting::Budget.create!(organization: organization, period: year, name: "Revised")
    revised.set_amounts!(account("4000").id => { month(12).id => 1_000_00 })
    get routes.reports_profit_and_loss_path(period_id: year.id, compare: "budget-#{revised.id}")

    expect(headings).to eq([ [ "", "Year 2026" ], [ "Account", "Actual", "Budget", "Variance", "%" ] ])
    expect(section("income").first).to eq([ "4000Sales", "220.00", "1,000.00", "(780.00) U", "-78.0%" ])
    expect(section("expense").first).to eq([ "6000Rent", "30.00", "0.00", "30.00 U", "—" ])
    expect(css_select("select[name=compare] option").map(&:text)).to include("Budget: Original", "Budget: Revised")
  end

  it "downloads with the actual, budget and variance columns" do
    get routes.reports_profit_and_loss_path(period_id: month(3).id, compare: "budget-#{budget.id}", format: :csv)
    expect(response.headers["Content-Disposition"]).to include("profit-and-loss-2026-03-01-to-2026-03-31-vs-budget-original.csv")
    csv = CSV.parse(response.body)
    expect(csv.first).to eq([ "Section", "Code", "Account", "Level", "Mar 2026 actual", "Mar 2026 budget", "Mar 2026 variance", "Mar 2026 variance %",
                              "Year to date actual", "Year to date budget", "Year to date variance", "Year to date variance %" ])
    expect(csv.find { |row| row[1] == "4000" }).to eq([ "Income", "4000", "Sales", "0", "120.00", "100.00", "20.00", "20.0", "220.00", "190.00", "30.00", "15.8" ])
  end

  it "says when the year has no budget" do
    get routes.reports_profit_and_loss_path(period_id: month(3, last_year).id, compare: "budget")
    expect(response.body).to include("There is no budget for 2025 yet.")
    expect(css_select("table[data-comparison]")).to be_empty
    expect(css_select("select[name=compare] option").map(&:text)).not_to include("Budget: Original")
  end

  it "links a budget to its comparison" do
    get routes.budget_path(budget)
    expect(css_select("a").map { |link| link["href"] }).to include(routes.reports_profit_and_loss_path(period_id: year.id, compare: "budget-#{budget.id}"))
  end
end
