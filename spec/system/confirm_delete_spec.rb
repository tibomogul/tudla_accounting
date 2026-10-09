require "rails_helper"
require_relative "../support/system"

RSpec.describe "Confirming a delete", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let!(:account) { create(:tudla_accounting_account, code: "1013", name: "Petty Cash", organization: organization) }

  before { sign_in_as(organization) }

  # Stimulus connects after the page loads; a click before then would submit unconfirmed.
  def wait_for_confirm = expect(page).to have_css("form[data-confirm-ready]")

  it "asks for a second click before deleting" do
    visit account_path(account)
    wait_for_confirm

    click_button "Delete"
    expect(page).to have_button("Delete 1013 - Petty Cash? Click again to confirm")
    expect(TudlaAccounting::Account.exists?(account.id)).to be(true)

    click_button "Delete 1013 - Petty Cash? Click again to confirm"
    expect(page).to have_current_path(accounts_path)
    expect(page).to have_content("Account 1013 - Petty Cash was deleted.")
    expect(TudlaAccounting::Account.exists?(account.id)).to be(false)
  end

  it "dismisses flash messages" do
    visit account_path(account)
    wait_for_confirm
    click_button "Delete"
    click_button "Delete 1013 - Petty Cash? Click again to confirm"
    expect(page).to have_current_path(accounts_path)

    within(".tc-alert") { click_button "Dismiss" }
    expect(page).to have_no_css(".tc-alert")
  end

  it "asks for a second click on input-type buttons too, e.g. reversing an entry" do
    TudlaAccounting::PeriodCreator.call(organization, Date.current.year)
    capital = create(:tudla_accounting_account, code: "3000", category: :equity, organization: organization)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: "Capital", transacted_at: Time.current)
    entry.details.build(account: account, tally: :debit, amount_cents: 100, currency: "AUD", organization: organization)
    entry.details.build(account: capital, tally: :credit, amount_cents: 100, currency: "AUD", organization: organization)
    entry.save!
    entry.post(entry.transacted_at)

    visit entry_path(entry)
    wait_for_confirm
    click_button "Reverse"
    expect(page).to have_button("Reverse this entry? Click again to confirm")
    expect(entry.reload.reversal).to be_nil

    click_button "Reverse this entry? Click again to confirm"
    # Only proves we left the entry's page: the reversal's id isn't known in advance.
    expect(page).to have_no_current_path(entry_path(entry))
    expect(page).to have_content("Entry reversed on")
    expect(entry.reload.reversal).to be_present
  end
end
