require "rails_helper"
require_relative "../../../../support/configuration"

RSpec.describe "JSON API: recurring invoices", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %w[read record post] }
  let(:secret) { TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: permissions).last }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer", payment_terms_days: 30) }
  let(:retainer) do
    { name: "Retainer", contact_id: northwind.id, reference: "PO 9", frequency: "monthly", interval: 1, day_of_month: 1, starts_on: "2026-05-01",
      lines: [ { description: "Support", quantity: "2", unit_price: "100", account_code: "4000", tax_code: "GST", dimensions: { "DEPT" => "SYD" } } ] }
  end

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }
    ], organization)
    TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200"))
    department = TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department")
    department.dimension_values.create!(code: "SYD", name: "Sydney")
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def json = JSON.parse(response.body)

  def call(method, path, body = {}, key: nil)
    headers = { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" }
    headers["Idempotency-Key"] = key if key
    public_send(method, path, params: (body.to_json unless method == :get), headers: headers)
    json if response.body.present?
  end

  it "sets one up, lists it, changes it and deletes it, leaving its invoices" do
    data = call(:post, routes.api_v1_recurring_invoices_path, retainer)["data"]
    expect(response).to have_http_status(:created)
    expect(data).to include("name" => "Retainer", "contact" => { "id" => northwind.id, "name" => "Northwind" }, "issue" => "draft", "frequency" => "monthly",
                            "day_of_month" => 1, "schedule" => "Every month on the 1st", "next_on" => "2026-05-01", "occurrences_count" => 0,
                            "active" => true, "currency" => "AUD", "total" => "220.00")
    expect(data["lines"]).to eq([ { "description" => "Support", "quantity" => "2.0", "unit_price" => "100.00", "amount" => "200.00", "account_code" => "4000",
                                    "tax_code" => "GST", "dimensions" => { "DEPT" => "SYD" } } ])

    changed = call(:patch, routes.api_v1_recurring_invoice_path(data["id"]), { day_of_month: "last", due_days: 14,
                                                                               lines: [ { description: "Hosting", unit_price: "50", account_code: "4000" } ] })["data"]
    expect(changed).to include("day_of_month" => nil, "schedule" => "Every month on the last day", "next_on" => "2026-05-31", "due_days" => 14, "total" => "50.00", "reference" => "PO 9")
    expect(changed["lines"].map { |line| line["description"] }).to eq([ "Hosting" ])
    expect(call(:patch, routes.api_v1_recurring_invoice_path(data["id"]), { active: false })["data"]["active"]).to be(false)

    expect(call(:get, routes.api_v1_recurring_invoices_path(active: false))["data"].map { |template| template["id"] }).to eq([ data["id"] ])
    expect(call(:get, routes.api_v1_recurring_invoices_path(active: true))["data"]).to be_empty
    expect(call(:get, routes.api_v1_recurring_invoices_path(contact_id: northwind.id))["meta"]["total_count"]).to eq(1)
    expect(call(:get, routes.api_v1_recurring_invoice_path(data["id"]))["data"]["name"]).to eq("Retainer")

    invoice = call(:post, routes.make_api_v1_recurring_invoice_path(data["id"]))["data"]
    call(:delete, routes.api_v1_recurring_invoice_path(data["id"]))
    expect(response).to have_http_status(:no_content)
    expect(TudlaAccounting::Document.find(invoice["id"]).recurring_invoice_id).to be_nil
  end

  it "makes the invoices due today, and a draft for a date once per Idempotency-Key" do
    template = call(:post, routes.api_v1_recurring_invoices_path, retainer.merge(starts_on: "2026-04-01", issue: "approve"))["data"]
    made = call(:post, routes.run_api_v1_recurring_invoices_path)["data"]
    expect(made["invoices"].map { |invoice| invoice.slice("issued_on", "status", "number", "due_on", "total") })
      .to eq([ { "issued_on" => "2026-04-01", "status" => "approved", "number" => "INV-0001", "due_on" => "2026-05-01", "total" => "220.00" } ])
    expect(made).to include("emailed_ids" => [], "problems" => [])
    expect(call(:post, routes.run_api_v1_recurring_invoices_path)["data"]["invoices"]).to be_empty

    draft = call(:post, routes.make_api_v1_recurring_invoice_path(template["id"]), { on: "2026-04-20" }, key: "one-off")["data"]
    expect(response).to have_http_status(:created)
    expect(draft).to include("status" => "draft", "issued_on" => "2026-04-20", "reference" => "PO 9")
    expect(call(:post, routes.make_api_v1_recurring_invoice_path(template["id"]), { on: "2026-04-20" }, key: "one-off")["data"]["id"]).to eq(draft["id"])
    expect(response).to have_http_status(:ok)
    expect(TudlaAccounting::Document.count).to eq(2)

    # A second request whose check ran before the first had committed: the database refuses it.
    checks = 0
    allow_any_instance_of(TudlaAccounting::Api::V1::RecurringInvoicesController).to receive(:replay).and_wrap_original do |original, *args|
      (checks += 1) == 1 ? nil : original.call(*args)
    end
    expect(call(:post, routes.make_api_v1_recurring_invoice_path(template["id"]), { on: "2026-04-20" }, key: "one-off")["data"]["id"]).to eq(draft["id"])
    expect(TudlaAccounting::Document.count).to eq(2)
  end

  it "says what's wrong with what was sent" do
    { retainer.except(:contact_id) => "Contact_id is missing",
      retainer.except(:lines) => "Lines must be a list",
      retainer.merge(frequency: "daily") => "Frequency is not included in the list",
      retainer.merge(day_of_month: "first") => "Day of month is not a number",
      retainer.merge(lines: []) => "Add at least one line",
      retainer.merge(lines: [ { description: "x", unit_price: "1", account_code: "1100" } ]) => "Lines account" }.each do |sent, message|
      call(:post, routes.api_v1_recurring_invoices_path, sent)
      expect(response).to have_http_status(:unprocessable_content), sent.inspect
      expect(json.dig("error", "message")).to start_with(message), sent.inspect
    end
    expect(TudlaAccounting::RecurringInvoice.count).to eq(0)
  end

  describe "with a token that records but can't post" do
    let(:permissions) { %w[read record] }

    it "sets up drafts, but not approving or emailing, nor runs them" do
      template = call(:post, routes.api_v1_recurring_invoices_path, retainer)["data"]
      call(:patch, routes.api_v1_recurring_invoice_path(template["id"]), { issue: "email" })
      expect(response).to have_http_status(:forbidden)
      expect(json.dig("error", "message")).to eq("This token can't post; issue one that can")
      call(:post, routes.api_v1_recurring_invoices_path, retainer.merge(issue: "approve"))
      expect(response).to have_http_status(:forbidden)
      call(:post, routes.run_api_v1_recurring_invoices_path)
      expect(response).to have_http_status(:forbidden)

      call(:post, routes.make_api_v1_recurring_invoice_path(template["id"]))
      expect(response).to have_http_status(:created)
      expect(TudlaAccounting::RecurringInvoice.sole.issue).to eq("draft")
    end
  end
end
