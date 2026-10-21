require "rails_helper"
require_relative "../support/system"

RSpec.describe "Setting up a recurring entry", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, Date.current.year)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash", category: "asset" }, { code: "6100", name: "Rent", category: "expense" }, { code: "6200", name: "Cleaning", category: "expense" }
    ], organization)
    sign_in_as(organization)
  end

  def line(index) = all("tbody[data-entry-lines-target=lines] tr:not([hidden])", minimum: index + 1)[index]

  it "totals the lines as they are typed, and saves the template" do
    visit new_recurring_entry_path
    fill_in "Name", with: "Rent"
    fill_in "Particulars", with: "Office rent and cleaning"
    within(line(0)) { select "6100 - Rent", from: "Account"; fill_in "Debit", with: "1000" }
    within(line(1)) { select "1010 - Cash", from: "Account"; fill_in "Credit", with: "1100" }
    expect(page).to have_css("[data-entry-lines-target=status]", text: /\ANot balanced/)

    click_button "Add line"
    within(line(2)) { select "6200 - Cleaning", from: "Account"; fill_in "Debit", with: "100" }
    expect(page).to have_css("[data-entry-lines-target=status]", exact_text: "Balanced: debits equal credits (1,100.00).")

    click_button "Save recurring entry"
    expect(page).to have_content("Recurring entry saved.")
    expect(TudlaAccounting::RecurringEntry.find_by!(name: "Rent").lines.map { |l| [ l.account.code, l.amount_cents ] })
      .to eq([ [ "6100", 1000_00 ], [ "1010", 1100_00 ], [ "6200", 100_00 ] ])
  end
end
