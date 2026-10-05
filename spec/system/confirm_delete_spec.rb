require "rails_helper"
require_relative "../support/system"

RSpec.describe "Confirming a delete", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let!(:account) { create(:tudla_accounting_account, code: "1013", name: "Petty Cash", organization: organization) }

  before { sign_in_as(organization) }

  it "asks for a second click before deleting" do
    visit "/tudla_accounting/accounts/#{account.id}"

    click_button "Delete"
    expect(page).to have_button("Delete 1013 - Petty Cash? Click again to confirm")
    expect(TudlaAccounting::Account.exists?(account.id)).to be(true)

    click_button "Delete 1013 - Petty Cash? Click again to confirm"
    expect(page).to have_content("Account 1013 - Petty Cash was deleted.")
    expect(TudlaAccounting::Account.exists?(account.id)).to be(false)
  end

  it "dismisses flash messages" do
    visit "/tudla_accounting/accounts/#{account.id}"
    click_button "Delete"
    click_button "Delete 1013 - Petty Cash? Click again to confirm"

    within(".tc-alert") { click_button "Dismiss" }
    expect(page).to have_no_css(".tc-alert")
  end
end
