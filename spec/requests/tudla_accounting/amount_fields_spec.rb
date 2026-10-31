require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

# Amount fields are filled as the forms read them back, in the organization's number
# format ("1000,50" in euro books, without thousands separators), so saving a form
# unchanged keeps its amounts; and quantities, rates and percentages are read and filled
# the same way.
RSpec.describe "Amount fields", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "EUR") } # written 1.000,50
  let(:permissions) { %i[read record post administer] }

  before do
    travel_to Time.zone.local(2026, 3, 15, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    @year = TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2200", name: "VAT", category: "liability" }, { code: "4000", name: "Sales", category: "income" }, { code: "6200", name: "Software", category: "expense" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def field(name) = css_select("input[name='#{name}']").first["value"]
  def northwind = TudlaAccounting::Contact.find_or_create_by!(organization: organization, name: "Northwind", kind: "customer")

  it "keeps a bank rule's amounts when it is saved unchanged" do
    rule = { name: "Adobe", description_contains: "adobe", account_id: account("1000").id, direction: "out", amount_min: "", amount_max: "1.000,50", counter_account_id: account("6200").id, particulars: "" }
    post routes.bank_rules_path, params: { bank_rule: rule }
    saved = TudlaAccounting::BankRule.sole
    expect(saved.amount_max_cents).to eq(1_000_50)
    get routes.edit_bank_rule_path(saved)
    expect(field("bank_rule[amount_max]")).to eq("1000,50")

    patch routes.bank_rule_path(saved), params: { bank_rule: rule.merge(amount_max: field("bank_rule[amount_max]")) }
    expect(saved.reload.amount_max_cents).to eq(1_000_50)
  end

  it "keeps a budget's amounts when it is saved unchanged" do
    budget = TudlaAccounting::Budget.create!(organization: organization, period: @year, name: "Plan")
    january = @year.children.order(:from_date).first
    name = "amounts[#{account("4000").id}][#{january.id}]"
    patch routes.budget_path(budget), params: { budget: { name: "Plan" }, amounts: { account("4000").id => { january.id => "1000,50" } } }
    get routes.edit_budget_path(budget)
    expect(field(name)).to eq("1000,50")

    patch routes.budget_path(budget), params: { budget: { name: "Plan" }, amounts: { account("4000").id => { january.id => field(name) } } }
    expect(budget.lines.sole.amount_cents).to eq(1_000_50)
  end

  it "reads an invoice line's quantity and price as amounts are read, and says how to write one it can't" do
    line = ->(quantity, price = "1,50") { { "0" => { description: "Hours", quantity: quantity, unit_price: price, account_id: account("4000").id } } }
    post routes.documents_path, params: { document: { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-03-10", lines: line.call("1.000") } }
    invoice = TudlaAccounting::Document.sole
    expect(invoice.lines.sole).to have_attributes(quantity: 1000, amount_cents: 1_500_00)
    get routes.edit_document_path(invoice)
    expect([ field("document[lines][0][quantity]"), field("document[lines][0][unit_price]") ]).to eq([ "1000", "1,50" ])

    post routes.documents_path, params: { document: { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-03-10", lines: line.call("2,5", "1.50") } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Line 1: 1.50 isn&#39;t an amount, written like 1.234,56")
    post routes.documents_path, params: { document: { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-03-10", lines: line.call("lots") } }
    expect(response.body).to include("Line 1: lots isn&#39;t a quantity")
  end

  it "reads and fills an invoice's exchange rate and a tax code's rate the same way" do
    post routes.documents_path, params: { document: { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-03-10", currency: "AUD", exchange_rate: "0,6125",
                                                      lines: { "0" => { description: "Work", quantity: "2,5", unit_price: "10", account_id: account("4000").id } } } }
    invoice = TudlaAccounting::Document.sole
    expect([ invoice.exchange_rate, invoice.lines.sole.quantity ]).to eq([ BigDecimal("0.6125"), BigDecimal("2.5") ])
    get routes.edit_document_path(invoice)
    expect([ field("document[exchange_rate]"), field("document[lines][0][quantity]") ]).to eq([ "0,6125", "2,5" ])
    get routes.document_path(invoice)
    expect(css_select("[data-exchange-rate]").first.text.squish).to start_with("In AUD at 0,6125 EUR")

    post routes.tax_codes_path, params: { tax_code: { code: "VAT", name: "VAT", rate_percent: "12,5", kind: "sales", account_id: account("2200").id } }
    vat = TudlaAccounting::TaxCode.sole
    expect([ vat.rate, vat.label ]).to eq([ BigDecimal("0.125"), "VAT (12,5%)" ])
    get routes.edit_tax_code_path(vat)
    expect(field("tax_code[rate_percent]")).to eq("12,5")
  end

  context "when the books are set to write numbers with a decimal point" do
    before { TudlaAccounting.configuration.number_format = :point }

    it "reads and fills them that way instead" do
      line = { "0" => { description: "Hours", quantity: "1,000", unit_price: "1.50", account_id: account("4000").id } }
      post routes.documents_path, params: { document: { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-03-10", lines: line } }
      invoice = TudlaAccounting::Document.sole
      expect(invoice.lines.sole).to have_attributes(quantity: 1000, amount_cents: 1_500_00)
      get routes.edit_document_path(invoice)
      expect(field("document[lines][0][unit_price]")).to eq("1.50")
      get routes.document_path(invoice)
      expect(response.body).to include("1,500.00")
    end
  end
end
