require "rails_helper"
require_relative "../support/system"

RSpec.describe "Withholding tax from a supplier's payment", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, Date.current.year)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "2350", name: "No-ABN withholding", category: "liability" }, { code: "6000", name: "Repairs", category: "expense" }
    ], organization)
    account = ->(code) { TudlaAccounting::Account.find_by!(organization: organization, code: code) }
    noabn = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "NOABN", name: "No ABN quoted", rate: "0.47", payable_account: account.call("2350"), withheld_on: "payment")
    supplier = TudlaAccounting::Contact.create!(organization: organization, name: "Handy Repairs", kind: "supplier", default_withholding_code: noabn)
    @bill = TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.current,
                                              lines_attributes: [ { description: "Repairs", unit_price_cents: 1_000_00, account: account.call("6000") } ]).approve!
    sign_in_as(organization)
  end

  it "works the tax out from the amount typed, and makes the cash that amount less the tax" do
    visit new_payment_path(document_id: @bill.id)
    expect(page).to have_field("Cash paid (AUD)", with: "530.00")
    fill_in "Withheld from 1", with: "600"
    expect(page).to have_field("Tax withheld 1", with: "282.00")
    expect(page).to have_field("Cash paid (AUD)", with: "318.00")
    fill_in "Tax withheld 1", with: "300"
    expect(page).to have_field("Cash paid (AUD)", with: "300.00")
  end
end
