require "rails_helper"
require_relative "../support/system"

RSpec.describe "Attaching a receipt", type: :system do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, Date.current.year)
    TudlaAccounting::AccountsCreator.call([ { code: "1010", name: "Cash", category: "asset" }, { code: "6000", name: "Rent", category: "expense" } ], organization)
    sign_in_as(organization)
  end

  it "uploads a receipt to a posted entry and lists it" do
    entry = TudlaAccounting::Entry.create_from_ruby_hash(
      organization_type: "Organization", organization_id: organization.id, particulars: "March rent", transacted_at: Date.current.beginning_of_month.to_time.utc.iso8601,
      details: [ { account_code: "6000", amount: "AUD 1200.00" }, { account_code: "1010", amount: "AUD -1200.00" } ]
    )
    entry.post(entry.transacted_at)

    visit entry_path(entry)
    attach_file "Attach receipts or documents", file_fixture("receipt.pdf")
    click_button "Attach"

    expect(page).to have_content("receipt.pdf attached.")
    within("[data-attachment]") { expect(page).to have_link("receipt.pdf", href: entry_attachment_path(entry, entry.attachments.first)) }
    expect(page).to have_field("Reason for removing receipt.pdf")
  end
end
