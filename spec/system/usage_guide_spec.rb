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
    expect(page).to have_current_path({ "Periods" => periods_path, "Setup" => setup_path, "Accounts" => accounts_path, "Contacts" => contacts_path,
                                          "Sales" => sales_documents_path, "Purchases" => purchase_documents_path, "Banking" => banking_path, "Reports" => reports_path }.fetch(name))
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
    expect(page).to have_content("Chart of accounts loaded: 83 new accounts, with opening balances.")
    expect(page).to have_content("Retained earnings") # the role's badge in the chart

    # 4. The Setup page shows the roles, and the account form sets one
    nav "Setup"
    expect(page).to have_content("Retained earnings account: 3030 - Retained Earnings")
    expect(page).to have_content("Receivables account: 1020 - Accounts Receivable · Payables account: 2011 - Accounts Payable")
    expect(page).to have_text(/· Realized gains and losses account:\s*none marked/)

    nav "Accounts"
    click_link "Interest Income"
    expect(page).to have_current_path(account_path(account("4091")))
    click_link "Edit"
    expect(page).to have_current_path(edit_account_path(account("4091")))
    select "Realized exchange gains and losses", from: "Role"
    click_button "Save account"
    expect(page).to have_current_path(account_path(account("4091")))
    expect(page).to have_content("Account 4091 - Interest Income was updated.")
    nav "Setup"
    expect(page).to have_content("Realized gains and losses account: 4091 - Interest Income")

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

  # Running the books, on books set up as the guide's first part leaves them.
  context "with the books set up" do
    let(:today) { Date.current }

    before do
      TudlaAccounting.configuration.reminder_days = [ 7, 14, 30 ]
      [ today.year - 1, today.year ].each { |calendar_year| TudlaAccounting::PeriodCreator.call(organization, calendar_year) }
      TudlaAccounting::AccountsCreator.call([
        { code: "1010", name: "Cash at bank", category: "asset" }, { code: "1100", name: "Accounts receivable", category: "asset", role: "receivable" },
        { code: "2100", name: "Accounts payable", category: "liability", role: "payable" }, { code: "2200", name: "GST", category: "liability" },
        { code: "4010", name: "Sales", category: "income" }, { code: "6000", name: "Expenses", category: "expense" }, { code: "6020", name: "Software", category: "expense" },
        { code: "6030", name: "Bank fees", category: "expense" }
      ], organization)
      gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST on sales", rate: "0.1", kind: :sales, account: account("2200"))
      gst_paid = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST-P", name: "GST on purchases", rate: "0.1", kind: :purchases, account: account("2200"))
      TudlaAccounting::Contact.create!(organization: organization, name: "Northwind Traders", kind: "customer", email: "accounts@northwind.test", payment_terms_days: 14,
                                       default_account: account("4010"), default_tax_code: gst)
      TudlaAccounting::Contact.create!(organization: organization, name: "Cloudnine Hosting", kind: "supplier", email: "billing@cloudnine.test", payment_terms_days: 30,
                                       default_account: account("6020"), default_tax_code: gst_paid)
      globex = TudlaAccounting::Contact.create!(organization: organization, name: "Globex", kind: "customer", email: "payables@globex.test", payment_terms_days: 30)
      # An invoice 15 days overdue, for the reminders
      TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: globex, issued_on: today - 45, due_on: today - 15,
                                        lines_attributes: [ { description: "Licence", quantity: 1, unit_price_cents: 1_000_00, account: account("4010") } ]).approve!
    end

    it "invoices, gets paid, pays suppliers, chases, reconciles and budgets" do
      # Invoices and bills: Sales → New invoice
      nav "Sales"
      click_link "New invoice"
      expect(page).to have_current_path(new_document_path, ignore_query: true)
      select "Northwind Traders", from: "Customer"
      expect(page).to have_field("Due", with: (today + 14).iso8601)
      fill_in "Description", with: "Consulting"
      fill_in "Quantity", with: "10"
      fill_in "Unit price", with: "150"
      within("tfoot") { expect(page).to have_content("1,650.00") }
      click_button "Save and approve"
      expect(page).to have_current_path(%r{/documents/\d+\z})
      expect(page).to have_content("Invoice INV-0002 approved and posted.")

      # Payments, credits and refunds: Record payment, then Refund to them
      click_link "Record payment"
      expect(page).to have_current_path(new_payment_path, ignore_query: true)
      select "1010 - Cash at bank", from: "Into"
      fill_in "Amount (USD)", with: "1,700.00"
      fill_in "Apply to INV-0002", with: "1,650.00"
      click_button "Record payment"
      expect(page).to have_current_path(%r{/payments/\d+\z})
      expect(page).to have_content("Payment from Northwind Traders of $1,700.00 recorded.")
      click_link "Refund to them"
      expect(page).to have_current_path(new_refund_path, ignore_query: true)
      fill_in "Amount (USD)", with: "50"
      click_button "Record refund"
      expect(page).to have_current_path(%r{/payments/\d+\z})
      expect(page).to have_content("of $50.00 recorded.")

      # Purchases → New bill, then Purchases → Pay run
      nav "Purchases"
      click_link "New bill"
      expect(page).to have_current_path(new_document_path, ignore_query: true)
      select "Cloudnine Hosting", from: "Supplier"
      fill_in "Description", with: "Hosting"
      fill_in "Unit price", with: "200"
      click_button "Save and approve"
      expect(page).to have_current_path(%r{/documents/\d+\z})
      expect(page).to have_content("Bill BILL-0001 approved and posted.")
      nav "Purchases"
      click_link "Pay run"
      expect(page).to have_current_path(new_pay_run_path, ignore_query: true)
      fill_in "Due by", with: today + 60
      click_button "Show bills"
      expect(page).to have_checked_field("Pay BILL-0001")
      wait_for_confirm
      click_button "Pay the chosen bills"
      click_button_and_reload "Pay the chosen bills? A payment to each supplier is recorded and posted. Click again to confirm"
      expect(page).to have_current_path(paid_payments_path)
      expect(page).to have_content("Paid 1 supplier $220.00 in all. Emailing payment notices to Cloudnine Hosting.")

      # Recurring invoices: Sales → Recurring invoices → New recurring invoice
      nav "Sales"
      click_link "Recurring invoices"
      expect(page).to have_current_path(recurring_invoices_path)
      click_link "New recurring invoice"
      expect(page).to have_current_path(new_recurring_invoice_path)
      fill_in "Name", with: "Support retainer"
      select "Northwind Traders", from: "Customer"
      fill_in "Description", with: "Support retainer"
      fill_in "Unit price", with: "500"
      fill_in "Starting", with: today
      select today.day.ordinalize, from: "On the"
      choose "Approved invoices"
      click_button "Save recurring invoice"
      expect(page).to have_current_path(%r{/recurring_invoices/\d+\z})
      expect(page).to have_content("Recurring invoice saved.")
      nav "Sales"
      click_link "Recurring invoices"
      expect(page).to have_current_path(recurring_invoices_path)
      wait_for_confirm
      click_button "Make the 1 due invoice now"
      click_button_and_reload "Make them now? Each is a draft, approved or emailed, as its template says. Click again to confirm"
      expect(page).to have_content("Made 1 invoice: 1 approved, 0 emailed.")

      # Statements and reminders: Reports → Statements; Sales → Reminders due
      nav "Reports"
      click_link "Statements"
      expect(page).to have_current_path(reports_statement_path, ignore_query: true)
      select "Northwind Traders", from: "Customer"
      fill_in "From", with: today.beginning_of_month
      fill_in "To", with: today
      click_button "Show"
      expect(page).to have_current_path(/party=/)
      expect(page).to have_content("550.00") # the retainer, still owed

      nav "Sales"
      click_link "Reminders due (1)"
      expect(page).to have_current_path(reminders_path)
      wait_for_confirm
      click_button "Send 1 reminder"
      click_button_and_reload "Email 1 reminder, each as the reminder template says? Click again to confirm"
      expect(TudlaAccounting::Delivery.where(organization: organization, kind: "reminder").pluck(:to)).to eq([ "payables@globex.test" ])

      # Banking: the account, Import statement, Match N suggestions; Bank rules; Record N lines by their rules
      statement = Rails.root.join("tmp/usage_guide_statement.csv")
      statement.write(<<~CSV)
        Date,Description,Amount,Reference
        #{today.iso8601},NORTHWIND TRADERS EFT,1700.00,EFT
        #{today.iso8601},REFUND NORTHWIND TRADERS,-50.00,
        #{today.iso8601},MONTHLY ACCOUNT FEE,-12.50,
        #{today.iso8601},CLOUDNINE HOSTING,-220.00,Pay run
      CSV
      nav "Banking"
      click_link "1010 - Cash at bank"
      expect(page).to have_current_path(banking_account_path(account("1010")))
      attach_file "Statement (CSV, OFX, QFX or CAMT.053)", statement
      click_button "Import statement"
      expect(page).to have_current_path(banking_account_path(account("1010")))
      expect(page).to have_content("Imported 4 statement lines from the CSV file")
      click_button_and_reload "Match 3 suggestions"
      expect(page).to have_content("Matched 3 statement lines.")
      click_link "Bank rules"
      expect(page).to have_current_path(bank_rules_path)
      click_link "New rule"
      expect(page).to have_current_path(new_bank_rule_path, ignore_query: true)
      fill_in "Name", with: "Bank fees"
      fill_in "Whose description contains", with: "account fee"
      select "6030 - Bank fees", from: "Against the account"
      click_button "Save rule"
      expect(page).to have_current_path(bank_rules_path)
      expect(page).to have_content("Bank rule Bank fees saved.")
      nav "Banking"
      click_link "1010 - Cash at bank"
      expect(page).to have_current_path(banking_account_path(account("1010")))
      wait_for_confirm
      click_button "Record 1 line by their rules"
      click_button_and_reload "Post an entry for each of these lines, as its rule says? Click again to confirm"
      expect(page).to have_content("Recorded 1 statement line by their rules.")

      # Budgets: Reports → Budgets → New budget, Add budget
      nav "Reports"
      click_link "Budgets"
      expect(page).to have_current_path(budgets_path)
      click_link "New budget"
      expect(page).to have_current_path(new_budget_path, ignore_query: true)
      select today.year.to_s, from: "For the year"
      fill_in "Name", with: "Plan"
      click_button "Add budget"
      expect(page).to have_current_path(%r{/budgets/\d+/edit\z})
      expect(page).to have_content("Budget Plan (#{today.year}) added. Enter its amounts.")
      fill_in "4010 - Sales, the year (spread over the months)", with: "24000"
      find("body").click
      click_button "Save budget"
      expect(page).to have_current_path(%r{/budgets/\d+\z})
      expect(page).to have_content("Budget Plan (#{today.year}) saved.")
    end
  end
end
