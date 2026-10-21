require "rails_helper"
require_relative "../support/system"

RSpec.describe "Writing an invoice", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, Date.current.year)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }, { code: "4100", name: "Other income", category: "income" }
    ], organization)
    gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales,
                                           account: TudlaAccounting::Account.find_by!(organization: organization, code: "2200"))
    TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", payment_terms_days: 14,
                                     default_account: TudlaAccounting::Account.find_by!(organization: organization, code: "4000"), default_tax_code: gst)
    sign_in_as(organization)
  end

  it "fills in the contact's terms and defaults, adds up the lines as they're typed, and approves it" do
    visit new_document_path(kind: "sales_invoice")
    fill_in "Date", with: Date.new(Date.current.year, 3, 2)
    select "Northwind", from: "Customer"
    expect(page).to have_field("Due", with: Date.new(Date.current.year, 3, 16).iso8601)
    expect(page).to have_select("Account", selected: "4000 - Sales")
    expect(page).to have_select("Tax", selected: "GST (10%)")

    fill_in "Description", with: "Consulting"
    fill_in "Quantity", with: "2.5"
    fill_in "Unit price", with: "1,000"
    within("tfoot") { expect(page).to have_content("2,500.00").and have_content("250.00").and have_content("2,750.00") }

    click_button "Add line"
    within(all("tr[data-document-lines-target=line]").last) do
      expect(page).to have_select("Account", selected: "4000 - Sales")
      fill_in "Description", with: "Travel"
      fill_in "Unit price", with: "110"
      select "No tax", from: "Tax"
      select "4100 - Other income", from: "Account"
    end
    check "Prices include the tax"
    within("tfoot") { expect(page).to have_content("2,382.73").and have_content("227.27").and have_content("2,610.00") }

    all("button[aria-label='Remove line']").last.click
    within("tfoot") { expect(page).to have_content("2,272.73").and have_content("2,500.00") }

    click_button "Save and approve"
    expect(page).to have_content("Invoice INV-0001 approved and posted.")
    within("[data-document]") { expect(page).to have_content("Consulting").and have_content("2,500.00") }
  end
end
