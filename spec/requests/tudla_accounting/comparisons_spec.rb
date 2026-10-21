require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "Comparative statements", type: :request do
  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let!(:last_year) { TudlaAccounting::PeriodCreator.call(organization, 2025) }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    sign_in_as(organization)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash", category: "asset" },
      { code: "3000", name: "Capital", category: "equity" },
      { code: "3900", name: "Retained earnings", category: "equity", role: "retained_earnings" },
      { code: "4000", name: "Sales", category: "income" },
      { code: "4100", name: "Interest", category: "income" },
      { code: "6000", name: "Rent", category: "expense" }
    ], organization)
    post_entry(2025, 2, "1010", "4000", 50)
    post_entry(2026, 2, "1010", "4000", 100)
    post_entry(2026, 3, "1010", "4000", 120)
    post_entry(2026, 3, "6000", "1010", 30)
    post_entry(2026, 2, "1010", "4100", 5) # only in February
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def month(year_period, number) = year_period.children.order(:from_date).to_a[number - 1]

  def post_entry(year_number, month_number, debit, credit, amount)
    at = Time.zone.local(year_number, month_number, 10)
    record = build(:tudla_accounting_entry, organization: organization, particulars: "Entry", transacted_at: at)
    record.details.build(account: account(debit), tally: :debit, amount_cents: amount * 100, currency: "AUD", organization: organization)
    record.details.build(account: account(credit), tally: :credit, amount_cents: amount * 100, currency: "AUD", organization: organization)
    record.save!
    record.post(at)
  end

  def table(category)
    section = css_select("section[aria-labelledby='section-#{category}'] table").first
    [ section.css("thead th").map { |cell| cell.text.squish }, *section.css("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } } ]
  end

  def figure(name) = css_select("tr[data-total='#{name}'] td").map { |cell| cell.text.squish }

  it "puts a month's profit and loss beside the month before, with the change" do
    get routes.reports_profit_and_loss_path(period_id: month(year, 3).id, compare: "previous")

    expect(table("income")).to eq([
      [ "Income", "Mar 2026", "Feb 2026", "Change", "%" ],
      [ "4000Sales", "120.00", "100.00", "20.00", "20.0%" ],
      [ "4100Interest", "0.00", "5.00", "(5.00)", "-100.0%" ], # in February only, still shown
      [ "Total income", "120.00", "105.00", "15.00", "14.3%" ]
    ])
    expect(table("expense")).to include([ "6000Rent", "30.00", "0.00", "30.00", "—" ])
    expect(figure("net_profit")).to eq([ "Net profit (loss)", "90.00", "105.00", "(15.00)", "-14.3%" ])
    expect(css_select("select[name=compare] option[selected]").map(&:text)).to eq([ "Previous period" ])
  end

  it "compares a year with the year before" do
    get routes.reports_profit_and_loss_path(period_id: year.id, compare: "last_year")
    expect(table("income").first(2)).to eq([ [ "Income", "Year 2026", "Year 2025", "Change", "%" ], [ "4000Sales", "220.00", "50.00", "170.00", "340.0%" ] ])
  end

  it "shows each month of a year and its total" do
    get routes.reports_profit_and_loss_path(period_id: year.id, compare: "months")

    headings = table("income").first
    expect(headings).to eq([ "Income", *%w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].map { |name| "#{name} 2026" }, "Total" ])
    expect(table("income")[1]).to eq([ "4000Sales", "0.00", "100.00", "120.00", *Array.new(9, "0.00"), "220.00" ])
  end

  it "shows a balance sheet at each month end so far, balanced at each" do
    get routes.reports_balance_sheet_path(period_id: month(year, 3).id, compare: "months")

    expect(table("asset")).to eq([ [ "Assets", "Jan 2026", "Feb 2026", "Mar 2026" ], [ "1010Cash", "50.00", "155.00", "245.00" ], [ "Total assets", "50.00", "155.00", "245.00" ] ])
    expect(figure("current_year_earnings")).to eq([ "Current-year earnings", "0.00", "105.00", "195.00" ])
    expect(response.body).to include("Balanced at each date")
  end

  it "says when there is nothing to compare with, showing the period alone" do
    get routes.reports_profit_and_loss_path(period_id: last_year.id, compare: "previous")
    expect(response.body).to include("There is no earlier period to compare with yet.")
    expect(css_select("[data-total=net_profit]").map { |cell| cell.text.squish }).to eq([ "50.00" ])

    get routes.reports_balance_sheet_path(period_id: month(last_year, 1).id, compare: "months")
    expect(response.body).to include("This is the first month of its year")

    get routes.reports_balance_sheet_path(period_id: month(last_year, 1).id, compare: "last_year")
    expect(response.body).to include("There is no period a year earlier")
  end

  it "ignores an unknown comparison" do
    get routes.reports_balance_sheet_path(period_id: month(year, 3).id, compare: "sideways")
    expect(response).to have_http_status(:ok)
    expect(css_select("section[aria-labelledby='section-asset'] thead th").size).to eq(2)
  end
end
