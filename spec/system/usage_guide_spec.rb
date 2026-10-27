require "rails_helper"
require_relative "../support/system"
require_relative "../support/configuration"

# USAGE.md's UI steps, followed in the browser by the names the guide gives them
# (Periods → New financial year, Setup → Manage tax codes...). Its console examples run
# in spec/integration/usage_guide_spec.rb.
RSpec.describe "USAGE.md, in the UI", type: :system do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, name: "Acme", currency: "USD") }
  let(:fixtures) { TudlaAccounting::Engine.root.join("spec/fixtures/files") }
  let(:year) { 2026 } # a year whose months have ended, for the revaluation and closing

  # The fixture chart with a Role column marking receivables, payables and retained earnings.
  let(:chart) do
    roles = { "1020" => "receivable", "2011" => "payable", "3030" => "Retained earnings" }
    rows = CSV.read(fixtures.join("coa_saas_services.csv"), headers: true)
    Rails.root.join("tmp/usage_guide_chart.csv").tap do |path|
      path.write(CSV.generate do |csv|
        csv << rows.headers + [ "Role" ]
        rows.each { |row| csv << row.fields + [ roles[row["Account Code"]] ] }
      end)
    end
  end

  before do
    TudlaAccounting.configuration.forex_rate_provider = ->(from:, to:, date:) { 1.6 }
    sign_in_as(organization)
  end

  # Every click that loads a page waits for it before looking at the content, or a query
  # can catch an element of the page being replaced (Chrome: "Node with given id does not
  # belong to the document").
  def nav(name)
    within("nav[aria-label=Accounting]") { click_link name }
    expect(page).to have_current_path({ "Periods" => periods_path, "Setup" => setup_path, "Accounts" => accounts_path, "Contacts" => contacts_path }.fetch(name))
  end

  def wait_for_confirm = expect(page).to have_css("form[data-confirm-ready]")

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  it "sets up the books step by step" do
    # 2. Periods → New financial year
    nav "Periods"
    click_link "New financial year"
    expect(page).to have_current_path(new_period_path)
    fill_in "Year", with: year
    select "January", from: "Starts in"
    fill_in "On day", with: "1"
    click_button "Create year"
    expect(page).to have_current_path(%r{/periods/\d+\z})
    expect(page).to have_content("Financial year #{year} was created.")

    # 3. Setup → Chart of accounts and opening balances, with the Role column
    nav "Setup"
    expect(page).to have_css("h2", text: "Chart of accounts and opening balances")
    attach_file "File", chart
    fill_in "Opening balances at", with: Date.new(year, 1, 1)
    expect(page).to have_unchecked_field("Replace accounts and opening balances that already exist")
    click_button "Load chart of accounts"
    expect(page).to have_current_path(accounts_path)
    expect(page).to have_content("Chart of accounts loaded: 81 new accounts, with opening balances.")
    expect(page).to have_content("Retained earnings") # the role's badge in the chart

    # 4. The Setup page shows the roles, and the account form sets one
    nav "Setup"
    expect(page).to have_content("Retained earnings account: 3030 - Retained Earnings")
    expect(page).to have_content("Receivables account: 1020 - Accounts Receivable · Payables account: 2011 - Accounts Payable")
    expect(page).to have_text(/· Realized gains and losses account:\s*none marked/)

    nav "Accounts"
    click_link "Other Income"
    expect(page).to have_current_path(account_path(account("4090")))
    click_link "Edit"
    expect(page).to have_current_path(edit_account_path(account("4090")))
    select "Realized exchange gains and losses", from: "Role"
    click_button "Save account"
    expect(page).to have_current_path(account_path(account("4090")))
    expect(page).to have_content("Account 4090 - Other Income was updated.")
    nav "Setup"
    expect(page).to have_content("Realized gains and losses account: 4090 - Other Income")

    # 5. Setup → Enter opening balances
    click_link "Enter opening balances"
    expect(page).to have_current_path(setup_opening_balances_path)
    expect(find("[data-opening-balances-target=status]").text).to eq("Balanced.")
    click_button "Save opening balances"
    expect(page).to have_current_path(reports_balance_sheet_path, ignore_query: true)
    expect(page).to have_content("Opening balances saved at 1 Jan #{year}.")

    # 6. Setup → Manage tax codes, and Manage dimensions, then add the values
    nav "Setup"
    click_link "Manage tax codes"
    expect(page).to have_current_path(tax_codes_path)
    click_link "New tax code"
    expect(page).to have_current_path(new_tax_code_path)
    fill_in "Code", with: "GST"
    fill_in "Name", with: "GST on sales"
    select "Sales (tax collected)", from: "For"
    fill_in "Rate (%)", with: "10"
    select "2040 - Sales Tax Payable", from: "Tax account"
    click_button "Save tax code"
    expect(page).to have_current_path(tax_codes_path)
    expect(page).to have_content("Tax code GST")
    expect(TudlaAccounting::TaxCode.find_by!(organization: organization, code: "GST").rate).to eq(BigDecimal("0.1"))

    nav "Setup"
    click_link "Manage dimensions"
    expect(page).to have_current_path(dimensions_path)
    click_link "New dimension"
    expect(page).to have_current_path(new_dimension_path)
    fill_in "Code", with: "DEPT"
    fill_in "Name", with: "Department"
    click_button "Save dimension"
    expect(page).to have_current_path(dimensions_path)
    expect(page).to have_content("was added. Add its values next.")
    click_link "Add value"
    expect(page).to have_current_path(%r{/dimensions/\d+/values/new\z})
    fill_in "Code", with: "SALES"
    fill_in "Name", with: "Sales"
    click_button "Save value"
    expect(page).to have_current_path(dimensions_path)
    expect(page).to have_content("was added.")

    # 7. Contacts → Import contacts (CSV or Excel)
    nav "Contacts"
    attach_file "Import contacts (CSV or Excel)", fixtures.join("contacts.csv")
    click_button "Import"
    expect(page).to have_current_path(contacts_path)
    expect(page).to have_content("3 contacts added and 0 updated from contacts.csv.")
    expect(page).to have_link("Northwind Traders").and have_link("Initech Supplies")
    expect(TudlaAccounting::Contact.find_by!(organization: organization, name: "Globex").default_tax_code.code).to eq("GST")

    # 8. Setup → Open receivables and payables
    nav "Setup"
    attach_file "CSV file", fixtures.join("carrying_amounts.csv")
    fill_in "Day before the cut-over", with: Date.new(year - 1, 12, 31)
    select "4011 - SaaS Subscription Fees", from: "Offset receivables against"
    select "8120 - Rent Expense", from: "Offset payables against"
    click_button "Import open items"
    expect(page).to have_current_path(reports_receivables_path)
    expect(page).to have_content("Imported 3 open items.")

    # Setup → Foreign exchange revaluation, which needs an unrealized gains account:
    # Accounts → "Add sub-account" on an account's page, with its role
    nav "Accounts"
    click_link "Other Income"
    expect(page).to have_current_path(account_path(account("4090")))
    click_link "Add sub-account"
    expect(page).to have_current_path(new_account_path, ignore_query: true)
    fill_in "Code", with: "4095"
    fill_in "Name", with: "Unrealized exchange gains"
    select "Unrealized exchange gains and losses", from: "Role"
    click_button "Create account"
    expect(page).to have_current_path(%r{/accounts/\d+\z})
    expect(page).to have_content("Account 4095 - Unrealized exchange gains was created.")
    nav "Setup"
    select "Jan #{year}", from: "At the end of"
    wait_for_confirm
    click_button "Run revaluation"
    click_button "Post revaluation entries? Click again to confirm"
    expect(page).to have_current_path(entries_path(q: "Revaluation"))
    expect(page).to have_content("Posted 2 revaluation entries for 31 Jan #{year}.")

    # 9. Setup → Check balances
    nav "Setup"
    click_link "Check balances"
    expect(page).to have_current_path(setup_balances_path)
    expect(page).to have_content("Every stored balance agrees with the posted entries.")

    # Closing periods: Periods, then the year; Close and Reopen on a month
    nav "Periods"
    click_link year.to_s
    expect(page).to have_current_path(%r{/periods/\d+\z})
    wait_for_confirm
    click_button "Close"
    click_button_and_reload "Close Jan #{year}? Nothing more can be posted to it. Click again to confirm"
    expect(page).to have_content("Jan #{year} is closed: nothing more can be posted to it.")
    fill_in "Reason for reopening Jan #{year}", with: "Late supplier bill"
    click_button_and_reload "Reopen"
    expect(page).to have_content("Jan #{year} is open again.")
  end
end
