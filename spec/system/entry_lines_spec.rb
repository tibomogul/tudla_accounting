require "rails_helper"
require_relative "../support/system"

RSpec.describe "Entering a journal entry", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, Date.current.year)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash", category: "asset" },
      { code: "3000", name: "Capital", category: "equity" },
      { code: "4000", name: "Sales", category: "income" }
    ], organization)
    sign_in_as(organization)
  end

  def status = find("[data-entry-lines-target=status]").text
  # Waits for the row to exist: one just added by "Add line" may not be rendered yet.
  def line(index) = all("tbody[data-entry-lines-target=lines] tr:not([hidden])", minimum: index + 1)[index]

  it "totals the lines as they are typed, then saves and posts the entry" do
    visit "/tudla_accounting/entries/new"
    expect(status).to eq("Enter the amounts for each line.")

    fill_in "Particulars", with: "Opening capital"
    within(line(0)) { select "1010 - Cash", from: "Account"; fill_in "Debit", with: "1,250.50" }
    within(line(1)) { select "3000 - Capital", from: "Account"; fill_in "Credit", with: "1000" }

    expect(page).to have_css("[data-entry-lines-target=debitTotal]", text: "1,250.50")
    expect(status).to eq("Not balanced: debits are 250.50 more.")

    click_button "Add line"
    within(line(2)) { select "4000 - Sales", from: "Account"; fill_in "Credit", with: "250.50" }
    expect(status).to eq("Balanced: debits equal credits (1,250.50).")

    click_button "Save draft"
    expect(page).to have_content("Draft entry saved.")
    click_button "Post"
    expect(page).to have_content("Entry posted.")

    entry = TudlaAccounting::Entry.find_by(particulars: "Opening capital")
    expect(entry).to be_posted
    expect(entry.details.sum(:amount_cents)).to eq(2 * 1250_50)
  end

  it "removes new lines, and saved ones on save" do
    visit "/tudla_accounting/entries/new"
    fill_in "Particulars", with: "Capital"
    within(line(0)) { select "1010 - Cash", from: "Account"; fill_in "Debit", with: "100" }
    within(line(1)) { select "3000 - Capital", from: "Account"; fill_in "Credit", with: "100" }
    click_button "Add line"
    within(line(2)) { fill_in "Debit", with: "5" }
    expect(status).to start_with("Not balanced")

    within(line(2)) { click_button "Remove line" }
    expect(status).to eq("Balanced: debits equal credits (100.00).")
    click_button "Save draft"
    expect(page).to have_content("Draft entry saved.")

    click_link "Edit"
    click_button "Add line"
    within(line(2)) { select "4000 - Sales", from: "Account"; fill_in "Credit", with: "100" }
    within(line(1)) { click_button "Remove line" } # the saved Capital line
    expect(status).to eq("Balanced: debits equal credits (100.00).")
    click_button "Save draft"

    expect(page).to have_content("Draft entry saved.")
    expect(TudlaAccounting::Entry.find_by(particulars: "Capital").details.map { |detail| detail.account.code }).to contain_exactly("1010", "4000")
  end

  it "adds the tax on taxed lines to the totals, or splits it out of amounts that include it" do
    gst = TudlaAccounting::Account.create!(organization: organization, code: "2200", name: "GST", category: "liability")
    TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST on sales", rate: "0.1", kind: :sales, account: gst)
    visit "/tudla_accounting/entries/new"

    fill_in "Particulars", with: "Taxed sale"
    within(line(0)) { select "1010 - Cash", from: "Account"; fill_in "Debit", with: "110" }
    within(line(1)) { select "4000 - Sales", from: "Account"; fill_in "Credit", with: "100"; select "GST (10%)", from: "Tax" }
    expect(page).to have_css("[data-entry-lines-target=creditTax]", text: "10.00")
    expect(status).to eq("Balanced: debits equal credits (110.00).")

    within(line(1)) { fill_in "Credit", with: "110" }
    expect(status).to eq("Not balanced: credits are 11.00 more.")
    check "Amounts on taxed lines include the tax"
    expect(status).to eq("Balanced: debits equal credits (110.00).")

    click_button "Save draft"
    expect(page).to have_content("Draft entry saved.")
    expect(TudlaAccounting::Entry.find_by(particulars: "Taxed sale").details.map { |d| [ d.account.code, d.amount_cents ] })
      .to contain_exactly([ "1010", 110_00 ], [ "4000", 100_00 ], [ "2200", 10_00 ])
  end
end
