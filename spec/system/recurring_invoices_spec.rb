require "rails_helper"
require_relative "../support/system"

RSpec.describe "Setting up a recurring invoice", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, Date.current.year)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }
    ], organization)
    gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: TudlaAccounting::Account.find_by!(code: "2200"))
    TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer", default_account: TudlaAccounting::Account.find_by!(code: "4000"), default_tax_code: gst)
    sign_in_as(organization)
  end

  it "fills a line from the customer, totals each invoice as it is typed, and saves the template" do
    visit new_recurring_invoice_path
    fill_in "Name", with: "Retainer"
    select "Northwind", from: "Customer"
    within("tbody[data-document-lines-target=lines] tr") do
      expect(page).to have_select("Account", selected: "4000 - Sales")
      fill_in "Description", with: "Monthly retainer"
      fill_in "Quantity", with: "2"
      fill_in "Unit price", with: "500"
    end
    expect(page).to have_css("[data-document-lines-target=total]", exact_text: "1,100.00")

    choose "Approved invoices, emailed to the customer"
    click_button "Save recurring invoice"
    expect(page).to have_content("Recurring invoice saved.")
    template = TudlaAccounting::RecurringInvoice.find_by!(name: "Retainer")
    expect(template).to have_attributes(issue: "email", total: Money.new(1_100_00, "AUD"))
  end
end
