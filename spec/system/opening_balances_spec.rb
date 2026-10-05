require "rails_helper"
require_relative "../support/system"

RSpec.describe "Entering opening balances", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash", category: "asset" },
      { code: "1500", name: "Equipment", category: "asset" },
      { code: "1505", name: "Accumulated Depreciation", category: "asset", contra_account: "1500" },
      { code: "3000", name: "Capital", category: "equity" }
    ], organization)
    sign_in_as(organization)
  end

  def status = find("[data-opening-balances-target=status]").text

  it "keeps debit and credit totals as amounts are typed, then saves" do
    visit "/tudla_accounting/setup/opening_balances"
    expect(status).to eq("Balanced.")

    fill_in "Cash", with: "1,000"
    fill_in "Equipment", with: "800"
    fill_in "Accumulated Depreciation", with: "200"
    expect(status).to eq("Not balanced: debits are 1,600.00 more.")

    fill_in "Capital", with: "1600"
    expect(status).to eq("Balanced.")
    expect(find("[data-opening-balances-target=debitTotal]").text).to eq("1,800.00")

    click_button "Save opening balances"
    expect(page).to have_content("Opening balances saved at 1 Jan 2026.")
    expect(page).to have_content("Balanced: assets equal liabilities plus equity")
  end
end
