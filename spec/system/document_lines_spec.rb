require "rails_helper"
require_relative "../support/system"
require_relative "../support/configuration"

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

    click_button_and_reload "Save and approve"
    expect(page).to have_content("Invoice INV-0001 approved and posted.")
    within("[data-document]") { expect(page).to have_content("Consulting").and have_content("2,500.00") }
  end

  it "asks for a rate in another currency, and works out the amounts in its minor units" do
    TudlaAccounting::Contact.create!(organization: organization, name: "Kaisha", currency: "JPY")
    visit new_document_path(kind: "sales_invoice")
    expect(page).to have_no_field("document[exchange_rate]")
    select "Kaisha", from: "Customer"
    expect(page).to have_select("Currency", selected: "JPY – Japanese Yen")
    expect(page).to have_field("Rate: 1 JPY in AUD")
    select "Northwind", from: "Customer"
    expect(page).to have_select("Currency", selected: "AUD – Australian Dollar")
    expect(page).to have_no_field("document[exchange_rate]")

    select "JPY – Japanese Yen", from: "Currency"
    expect(page).to have_field("Rate: 1 JPY in AUD")
    expect(page).to have_css("[data-document-lines-target=currencyLabel]", exact_text: "JPY")
    fill_in "Unit price", with: "1500"
    within("tfoot") { expect(page).to have_content("1,500") }

    select "AUD – Australian Dollar", from: "Currency"
    expect(page).to have_no_field("document[exchange_rate]")
    within("tfoot") { expect(page).to have_content("1,500.00") }
  end

  it "reads quantities and prices as the server does: thousands commas, and nothing it can't read" do
    visit new_document_path(kind: "sales_invoice")
    fill_in "Quantity", with: "1,000"
    fill_in "Unit price", with: "1.50"
    within("tfoot") { expect(page).to have_content("1,500.00") }
    fill_in "Quantity", with: "1e3"
    within("tfoot") { expect(page).to have_css("[data-document-lines-target=total]", exact_text: "0.00") }
  end

  context "when the books are in euros" do
    let(:organization) { create(:organization, name: "Acme", currency: "EUR") }

    it "reads and adds up the lines in the organization's style, as its pages show amounts" do
      visit new_document_path(kind: "sales_invoice")
      fill_in "Quantity", with: "1.000"
      fill_in "Unit price", with: "1,50"
      within("tfoot") { expect(page).to have_css("[data-document-lines-target=subtotal]", exact_text: "1.500,00") }
    end
  end

  context "when the books are set to write numbers with a decimal point" do
    let(:organization) { create(:organization, name: "Acme", currency: "EUR") }

    include_context "with isolated TudlaAccounting configuration"

    before { TudlaAccounting.configuration.number_format = :point }

    it "adds up the lines in that style" do
      visit new_document_path(kind: "sales_invoice")
      fill_in "Quantity", with: "1,000"
      fill_in "Unit price", with: "1.50"
      within("tfoot") { expect(page).to have_css("[data-document-lines-target=subtotal]", exact_text: "1,500.00") }
    end
  end

  it "starts a bill's lines with the supplier's withholding code, and takes it off what is payable as it's typed" do
    TudlaAccounting::AccountsCreator.call([ { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2300", name: "Withholding payable", category: "liability" },
                                            { code: "6000", name: "Repairs", category: "expense" } ], organization)
    account = ->(code) { TudlaAccounting::Account.find_by!(organization: organization, code: code) }
    TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC100", name: "Rent", rate: "0.05", payable_account: account.call("2300"))
    contractors = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Contractors", rate: "0.02", payable_account: account.call("2300"))
    TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier", default_account: account.call("6000"), default_withholding_code: contractors)

    visit new_document_path(kind: "bill")
    fill_in "Date", with: Date.new(Date.current.year, 3, 2)
    select "Ledger & Co", from: "Supplier"
    expect(page).to have_select("Withheld", selected: "WC120 (2%)")

    fill_in "Description", with: "Aircon repair"
    fill_in "Unit price", with: "10,000"
    within("tfoot") { expect(page).to have_content("Less tax withheld 200.00").and have_content("Amount payable 9,800.00") }

    select "WC100 (5%)", from: "Withheld"
    within("tfoot") { expect(page).to have_content("Less tax withheld 500.00").and have_content("Amount payable 9,500.00") }

    click_button_and_reload "Save and approve"
    expect(page).to have_content("approved and posted.")
    within("[data-document]") { expect(page).to have_content("Less tax withheld, WC100 (5%)").and have_content("9,500.00") }
  end

  it "shows a bill's whole unit price and codes with withholding and a dimension, without scrolling the table on a wide screen" do
    page.current_window.resize_to(1400, 900)
    TudlaAccounting::AccountsCreator.call([ { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2300", name: "Withholding payable", category: "liability" },
                                            { code: "6000", name: "Repairs", category: "expense" } ], organization)
    account = ->(code) { TudlaAccounting::Account.find_by!(organization: organization, code: code) }
    TudlaAccounting::TaxCode.create!(organization: organization, code: "IN12", name: "Input VAT", rate: "0.12", kind: :purchases, account: account.call("2200"))
    TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Contractors", rate: "0.02", payable_account: account.call("2300"))
    TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department").dimension_values.create!(code: "ENG", name: "Eng")

    visit new_document_path(kind: "bill")
    select "IN12 (12%)", from: "Tax"
    select "WC120 (2%)", from: "Withheld"
    fill_in "Unit price", with: "1,234,567.89"
    fits = ->(label) { page.evaluate_script("(() => { const e = document.querySelector(`[aria-label='${#{label.to_json}}']`); const c = document.createElement('canvas').getContext('2d'); c.font = getComputedStyle(e).font; const s = getComputedStyle(e); const text = e.tagName === 'SELECT' ? e.selectedOptions[0].text : e.value; return c.measureText(text).width <= e.clientWidth - parseFloat(s.paddingLeft) - parseFloat(s.paddingRight); })()") }
    expect(%w[Tax Withheld].push("Unit price").map(&fits)).to all(be(true))
    widths = page.evaluate_script("(() => { const c = document.querySelector('table').parentElement; return [c.scrollWidth, c.clientWidth, window.innerWidth, ...[...document.querySelector('tbody tr').children].map(td => Math.round(td.getBoundingClientRect().width))]; })()")
    expect(widths[0]).to be <= widths[1], widths.inspect
  end

  it "brings the cash down by the tax typed on a payment started from an invoice, until the cash is changed by hand" do
    TudlaAccounting::AccountsCreator.call([ { code: "1010", name: "Bank", category: "asset" }, { code: "1200", name: "Creditable tax", category: "asset" } ], organization)
    account = ->(code) { TudlaAccounting::Account.find_by!(organization: organization, code: code) }
    TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC160", name: "Services", rate: "0.02", creditable_account: account.call("1200"))
    customer = TudlaAccounting::Contact.create!(organization: organization, name: "Tala Logistics Inc.", kind: "customer")
    invoice = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: customer, issued_on: Date.new(Date.current.year, 3, 2),
                                                lines_attributes: [ { description: "Work", unit_price_cents: 56_000_00, account: account.call("4000") } ]).approve!

    visit new_payment_path(document_id: invoice.id)
    expect(page).to have_content("stays as a credit for Tala Logistics Inc.")
    expect(page).to have_no_content("Inc..")
    expect(page).to have_field("Cash received (#{organization.currency})", with: "56000.00")
    fill_in "Tax withheld 1", with: "1,000"
    expect(page).to have_field("Cash received (#{organization.currency})", with: "55000.00")
    fill_in "Tax withheld 1", with: ""
    expect(page).to have_field("Cash received (#{organization.currency})", with: "56000.00")

    fill_in "Cash received (#{organization.currency})", with: "40000"
    fill_in "Tax withheld 1", with: "1,000"
    expect(page).to have_field("Cash received (#{organization.currency})", with: "40000")

    visit new_payment_path(document_id: invoice.id)
    select "1010 - Bank", from: "Into"
    select "WC160 (2%) Services", from: "Withholding code 1"
    fill_in "Tax withheld 1", with: "1,000"
    fill_in "Income 1", with: ""
    click_button "Record payment"
    expect(page).to have_current_path(%r{/payments/\d+\z})
    expect(page).to have_content("55,000.00").and have_content("Applied")
    expect(invoice.reload.payment_status).to eq("paid")
  end
end
