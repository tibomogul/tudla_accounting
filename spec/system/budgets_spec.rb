require "rails_helper"
require_relative "../support/system"

RSpec.describe "Entering a budget", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:year) { TudlaAccounting::PeriodCreator.call(organization, Date.current.year) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "4000", name: "Sales", category: "income", children: [ { code: "4010", name: "Products", category: "income" } ] },
      { code: "4900", name: "Sales returns", category: "income", contra_account: "4010" }, { code: "6100", name: "Rent", category: "expense" }
    ], organization)
    sign_in_as(organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  it "spreads a year's total over the months and keeps the totals up to date" do
    budget = TudlaAccounting::Budget.create!(organization: organization, period: year, name: "Original")
    january, december = year.children.order(:from_date).to_a.values_at(0, -1)
    visit edit_budget_path(budget)

    fill_in "4010 - Products, the year (spread over the months)", with: "1000"
    find("body").click # leaves the field, so it changes
    expect(page).to have_field("4010 - Products, #{january.label}", with: "83.33")
    expect(page).to have_field("4010 - Products, #{december.label}", with: "83.37")
    within("tr[data-account-row='4000']") { expect(page).to have_css("[data-month=year]", text: "1,000.00") }

    fill_in "4900 - Sales returns, #{january.label}", with: "100"
    fill_in "6100 - Rent, #{january.label}", with: "50"
    within("[data-total=income]") { expect(page).to have_css("[data-month='#{january.id}']", text: "(16.67)") }
    within("[data-total=net_profit]") do
      expect(page).to have_css("[data-month='#{january.id}']", text: "(66.67)")
      expect(page).to have_css("[data-month=year]", text: "850.00")
    end

    click_button "Save budget"
    expect(page).to have_current_path(budget_path(budget))
    expect(budget.reload.amounts.dig(account("4010").id, december.id)).to eq(83_37)
  end
end
