require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

# Only accounts without sub-accounts take postings (see account_hierarchy_spec), so the
# forms offer only those, keeping one a record names already, marked.
RSpec.describe "Accounts that take postings", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before do
    TudlaAccounting.configuration.authorize = ->(_controller, _permission) { true }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank accounts", category: "asset", children: [ { code: "1010", name: "Cheque account", category: "asset" } ] },
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "2200", name: "GST", category: "liability" }, { code: "3000", name: "Capital", category: "equity" },
      { code: "4000", name: "Sales", category: "income", children: [ { code: "4010", name: "Services", category: "income" } ] },
      { code: "6000", name: "Expenses", category: "expense", children: [ { code: "6010", name: "Bank fees", category: "expense" } ] }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def options(selector) = css_select(selector).first.css("option").map(&:text)
  def select_options(name) = options("select[name='#{name}']")
  def offers(choices, account)
    expect(choices).to include(account)
    expect(choices).not_to include(*parents)
  end

  def parents = [ a_string_starting_with("1000 "), a_string_starting_with("4000 "), a_string_starting_with("6000 "), a_string_starting_with("1100 ") ]

  it "offers only accounts without sub-accounts where a line will post" do
    get routes.new_entry_path
    line = options("tbody[data-entry-lines-target=lines] select[name$='[account_id]']")
    expect(line).to include("1010 - Cheque account", "1100-AUD - Receivables - AUD", "4010 - Services", "6010 - Bank fees")
    expect(line).not_to include(*parents)

    get routes.new_document_path(kind: "sales_invoice")
    offers(options("select[aria-label=Account]"), "4010 - Services")
    get routes.new_recurring_invoice_path
    offers(options("select[aria-label=Account]"), "4010 - Services")
    get routes.new_recurring_entry_path
    offers(options("select[name$='[account_id]']"), "6010 - Bank fees")

    get routes.new_contact_path
    offers(select_options("contact[default_account_id]"), "4010 - Services")
    get routes.new_tax_code_path
    offers(select_options("tax_code[account_id]"), "2200 - GST")
    get routes.new_bank_rule_path
    offers(select_options("bank_rule[account_id]"), "1010 - Cheque account")
    offers(select_options("bank_rule[counter_account_id]"), "6010 - Bank fees")

    customer = TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer")
    get routes.new_payment_path(kind: "received", contact_id: customer.id)
    expect(select_options("payment[account_id]")).to eq([ "Choose an account", "1010 - Cheque account", "2200 - GST" ])
    get routes.new_pay_run_path
    expect(select_options("account_id")).to eq([ "1010 - Cheque account", "2200 - GST" ])

    # Parent, contra and filter choices still list every account.
    get routes.new_account_path
    expect(select_options("account[parent_id]")).to include("4000 - Sales")
    get routes.entries_path
    expect(select_options("account_id")).to include("4000 - Sales")
  end

  it "keeps an account a record names already, marked as having sub-accounts" do
    travel = TudlaAccounting::Account.create!(organization: organization, code: "6500", name: "Travel", category: :expense)
    draft = build(:tudla_accounting_entry, organization: organization, particulars: "Taxi", transacted_at: Time.zone.local(2026, 2, 10))
    draft.details.build(account: travel, tally: :debit, amount_cents: 500, currency: "AUD", organization: organization)
    draft.details.build(account: account("1010"), tally: :credit, amount_cents: 500, currency: "AUD", organization: organization)
    draft.save!
    contact = TudlaAccounting::Contact.create!(organization: organization, name: "Cabs", kind: "supplier", default_account: travel)
    TudlaAccounting::Account.create!(organization: organization, code: "6510", name: "Taxis", category: :expense, parent: travel)

    get routes.edit_entry_path(draft)
    expect(options("tbody[data-entry-lines-target=lines] select[name$='[account_id]']")).to include("6500 - Travel (has sub-accounts)", "6510 - Taxis")
    get routes.edit_contact_path(contact)
    expect(select_options("contact[default_account_id]")).to include("6500 - Travel (has sub-accounts)")

    post routes.post_entry_path(draft)
    expect(flash[:alert]).to start_with("The entry could not be posted: 6500 - Travel has sub-accounts (6510), so it can't take postings; use one of them")
  end

  it "refuses an invoice line on an account with sub-accounts" do
    contact = TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer")
    post routes.documents_path, params: { document: { kind: "sales_invoice", contact_id: contact.id, issued_on: "2026-03-01",
                                                      lines: { "0" => { description: "Work", quantity: "1", unit_price: "100", account_id: account("4000").id } } } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("4000 - Sales has sub-accounts (4010), so it can&#39;t take postings; use one of them")
  end

  describe "the JSON API" do
    let(:secret) { TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: %w[read record post]).last }

    def call(path, body)
      post path, params: body.to_json, headers: { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" }
      JSON.parse(response.body).dig("error", "message")
    end

    it "says a line can't go to an account with sub-accounts" do
      sale = { date: "2026-04-10", particulars: "Cash sale", lines: [ { account_code: "1010", debit: "100" }, { account_code: "4000", credit: "100" } ] }
      expect(call(routes.api_v1_entries_path, sale)).to eq("4000 - Sales has sub-accounts (4010), so it can't take postings; use one of them")
      expect(response).to have_http_status(:unprocessable_content)

      contact = TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer")
      invoice = { kind: "sales_invoice", contact_id: contact.id, issued_on: "2026-04-10", lines: [ { description: "Work", unit_price: "100", account_code: "4000" } ] }
      expect(call(routes.api_v1_documents_path, invoice)).to eq("Lines account 4000 - Sales has sub-accounts (4010), so it can't take postings; use one of them")
      expect(TudlaAccounting::Entry.count + TudlaAccounting::Document.count).to eq(0)
    end
  end
end
