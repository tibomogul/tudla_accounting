require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Inactive accounts", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post administer] }

  before do
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash", category: "asset" },
      { code: "1500", name: "Equipment", category: "asset", children: [ { code: "1510", name: "Fax machines", category: "asset" } ] },
      { code: "3000", name: "Capital", category: "equity" },
      { code: "6000", name: "Printing", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def options(name) = css_select("select[name='#{name}'] option").map(&:text)
  def line_options = css_select("tbody[data-entry-lines-target=lines] select[name$='[account_id]']").first.css("option").map(&:text)

  def draft(code)
    record = build(:tudla_accounting_entry, organization: organization, particulars: "Toner", transacted_at: Time.zone.local(2026, 2, 10))
    record.details.build(account: account(code), tally: :debit, amount_cents: 500, currency: "AUD", organization: organization)
    record.details.build(account: account("1010"), tally: :credit, amount_cents: 500, currency: "AUD", organization: organization)
    record.tap(&:save!)
  end

  it "makes an account inactive from its page, and active again" do
    post routes.deactivate_account_path(account("1500"))
    expect(response).to redirect_to(routes.account_path(account("1500")))
    expect(flash[:notice]).to eq("1500 - Equipment and 1 sub-account made inactive: no longer offered for new entries.")

    get routes.accounts_path
    inactive = css_select("tbody tr").select { |row| row.text.include?("Inactive") }.map { |row| row.css("td").first.text.squish }
    expect(inactive).to eq(%w[1500 1510])

    get routes.account_path(account("1510"))
    expect(css_select("form button").map(&:text)).not_to include("Reactivate") # its parent comes first
    get routes.account_path(account("1500"))
    expect(css_select("form button").map(&:text)).to include("Reactivate")
    expect(response.body).not_to include("Add sub-account")

    post routes.reactivate_account_path(account("1500"))
    expect(flash[:notice]).to eq("1500 - Equipment is active again.")

    get routes.activity_path
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish }).to include("Reactivated 1500 - Equipment", "Made 1500 - Equipment inactive with 1510")
  end

  it "says why an account can't be made inactive" do
    TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :purchases, account: account("6000"))
    post routes.deactivate_account_path(account("6000"))
    expect(flash[:alert]).to eq("6000 - Printing is where the GST tax code posts; change its account or make it inactive first.")
    post routes.reactivate_account_path(account("6000"))
    expect(flash[:alert]).to eq("6000 - Printing is active already.")
  end

  it "leaves inactive accounts out of new lines, but keeps them on a draft's own lines and in the filters" do
    kept = draft("6000")
    account("6000").deactivate!

    get routes.new_entry_path
    expect(line_options).not_to include(a_string_including("6000"))
    get routes.edit_entry_path(kept)
    expect(line_options).to include("6000 - Printing (inactive)")
    get routes.entries_path
    expect(options("account_id")).to include("6000 - Printing (inactive)")
    get routes.reports_general_ledger_path
    expect(options("account_id")).to include("6000 - Printing (inactive)")
    get routes.new_account_path
    expect(options("account[parent_id]")).not_to include(a_string_including("6000"))

    account("1500").deactivate!
    get routes.banking_path
    expect(css_select("#other-accounts + ul a").map(&:text)).to eq([ "1010 - Cash" ]) # none inactive to start reconciling
  end

  it "refuses an inactive account on a new line, but keeps one a saved line has" do
    kept = draft("6000")
    account("6000").deactivate!
    debit, credit = kept.details.sort_by { |line| line.debit? ? 0 : 1 }

    patch routes.entry_path(kept), params: { entry: { particulars: "Toner, corrected", transacted_at: "2026-02-10", lines: {
      "0" => { id: debit.id, account_id: account("6000").id, debit: "6", credit: "" },
      "1" => { id: credit.id, account_id: account("1010").id, debit: "", credit: "6" }
    } } }
    expect(response).to redirect_to(routes.entry_path(kept))
    expect(kept.reload.particulars).to eq("Toner, corrected")

    post routes.entries_path, params: { entry: { particulars: "More toner", transacted_at: "2026-02-11", lines: {
      "0" => { account_id: account("6000").id, debit: "5", credit: "" },
      "1" => { account_id: account("1010").id, debit: "", credit: "5" }
    } } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Line 1: 6000 - Printing is inactive")
  end

  context "when allowed only to read" do
    let(:permissions) { %i[read] }

    it "neither deactivates nor reactivates" do
      post routes.deactivate_account_path(account("6000"))
      expect(response).to have_http_status(:forbidden)
      expect(account("6000")).to be_active
    end
  end
end
