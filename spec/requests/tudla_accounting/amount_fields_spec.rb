require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

# Amount fields are filled as the forms read them back ("1000.50"), whatever the
# currency's own style, so saving a form unchanged keeps its amounts; and quantities are
# read as amounts are.
RSpec.describe "Amount fields", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "EUR") } # written 1.000,50
  let(:permissions) { %i[read record post] }

  before do
    travel_to Time.zone.local(2026, 3, 15, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    @year = TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "4000", name: "Sales", category: "income" }, { code: "6200", name: "Software", category: "expense" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def field(name) = css_select("input[name='#{name}']").first["value"]

  it "keeps a bank rule's amounts when it is saved unchanged" do
    rule = { name: "Adobe", description_contains: "adobe", account_id: account("1000").id, direction: "out", amount_min: "", amount_max: "1000.50", counter_account_id: account("6200").id, particulars: "" }
    post routes.bank_rules_path, params: { bank_rule: rule }
    saved = TudlaAccounting::BankRule.sole
    get routes.edit_bank_rule_path(saved)
    expect(field("bank_rule[amount_max]")).to eq("1000.50")

    patch routes.bank_rule_path(saved), params: { bank_rule: rule.merge(amount_max: field("bank_rule[amount_max]")) }
    expect(saved.reload.amount_max_cents).to eq(1_000_50)
  end

  it "keeps a budget's amounts when it is saved unchanged" do
    budget = TudlaAccounting::Budget.create!(organization: organization, period: @year, name: "Plan")
    january = @year.children.order(:from_date).first
    name = "amounts[#{account("4000").id}][#{january.id}]"
    patch routes.budget_path(budget), params: { budget: { name: "Plan" }, amounts: { account("4000").id => { january.id => "1000.50" } } }
    get routes.edit_budget_path(budget)
    expect(field(name)).to eq("1000.50")

    patch routes.budget_path(budget), params: { budget: { name: "Plan" }, amounts: { account("4000").id => { january.id => field(name) } } }
    expect(budget.lines.sole.amount_cents).to eq(1_000_50)
  end

  it "reads an invoice line's quantity as amounts are read, and says when it isn't one" do
    northwind = TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer")
    line = ->(quantity) { { "0" => { description: "Hours", quantity: quantity, unit_price: "1.50", account_id: account("4000").id } } }
    post routes.documents_path, params: { document: { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-03-10", lines: line.call("1,000") } }
    expect(TudlaAccounting::Document.sole.lines.sole).to have_attributes(quantity: 1000, amount_cents: 1_500_00)

    post routes.documents_path, params: { document: { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-03-10", lines: line.call("lots") } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Line 1: lots isn&#39;t a quantity")
  end
end
