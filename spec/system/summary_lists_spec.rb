require "rails_helper"
require_relative "../support/system"

RSpec.describe "The summary list of purchases", type: :system do
  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, Date.current.year)
    TudlaAccounting::AccountsCreator.call([
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2200", name: "VAT", category: "liability" }, { code: "6000", name: "Fees", category: "expense" }
    ], organization)
    account = ->(code) { TudlaAccounting::Account.find_by!(organization: organization, code: code) }
    code = TudlaAccounting::TaxCode.create!(organization: organization, code: "IN", name: "Input", kind: :purchases, rate: "0.12", account: account.call("2200"))
    supplier = TudlaAccounting::Contact.create!(organization: organization, name: "Sampaguita Consulting and Engineering Services Corp.", kind: "supplier", tax_number: "000-222-333-00000", address: "2 Made-up Street, Barangay Long Name, Quezon City", postal_code: "1100")
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.current,
                                      lines_attributes: [ { description: "Work", unit_price_cents: 1_234_567_89, account: account.call("6000"), tax_code: code } ]).approve!
    sign_in_as(organization)
  end

  def widths = page.evaluate_script("(() => { const card = document.querySelector('section[aria-label=Purchases]'); return { card: card.clientWidth, table: card.scrollWidth, page: document.documentElement.scrollWidth, window: document.documentElement.clientWidth }; })()")

  # Whether it all fits a desktop depends on the font, so that isn't checked here.
  it "scrolls inside its card on a phone, not the whole page" do
    size = page.current_window.size
    page.current_window.resize_to(420, 800)
    visit reports_purchases_list_path
    expect(page).to have_css("[data-list-row]")
    narrow = widths
    expect(narrow["table"]).to be > narrow["card"]
    expect(narrow["page"]).to be <= narrow["window"], narrow.inspect
  ensure
    page.current_window.resize_to(*size) if size
  end
end
