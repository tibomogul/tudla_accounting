require "rails_helper"
require_relative "../../../../support/configuration"

RSpec.describe "JSON API: reading the books", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %w[read] }
  let(:issued) { TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: permissions) }
  let(:token) { issued.first }
  let(:headers) { { "Authorization" => "Bearer #{issued.last}" } }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", email: "ap@northwind.test", payment_terms_days: 30) }
  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200")) }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2200", name: "GST", category: "liability" }, { code: "3000", name: "Capital", category: "equity" },
      { code: "4000", name: "Sales", category: "income", children: [ { code: "4010", name: "Consulting", category: "income" } ] }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def json = JSON.parse(response.body)

  def api_get(path, **params)
    get path, params: params, headers: headers
    json
  end

  def invoice!
    TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 4, 1), due_on: Date.new(2026, 5, 1),
                                      reference: "PO 9", lines_attributes: [ { description: "Consulting", quantity: "2.5", unit_price_cents: 100_00, account: account("4010"), tax_code: gst } ]).approve!
  end

  describe "authentication" do
    it "needs an active token, and says so" do
      get routes.api_v1_organization_path
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq('Bearer realm="TudlaAccounting", error="invalid_token"')
      expect(json).to eq("error" => { "code" => "invalid_token", "message" => "Send an API token as Authorization: Bearer <token>" })

      get routes.api_v1_organization_path, headers: { "Authorization" => "Bearer tudla_nope" }
      expect(json.dig("error", "message")).to eq("The token is unknown, revoked or expired")
      token.revoke!
      get routes.api_v1_organization_path, headers: headers
      expect(response).to have_http_status(:unauthorized)
    end

    it "shows the organization the token reaches, and only its books, without the host's sign-in" do
      expect(api_get(routes.api_v1_organization_path)).to eq("data" => { "id" => organization.id, "name" => "Acme", "currency" => "AUD",
                                                                         "token" => { "name" => "Shop", "permissions" => [ "read" ], "expires_on" => nil } })
      expect(token.reload.last_used_at).to be_present

      other = create(:organization)
      theirs = TudlaAccounting::Contact.create!(organization: other, name: "Theirs")
      get routes.api_v1_contact_path(theirs), headers: headers
      expect(response).to have_http_status(:not_found)
      expect(json).to eq("error" => { "code" => "not_found", "message" => "Not found" })
    end

    it "limits each token's requests a minute" do
      TudlaAccounting.configuration.api_rate_limit = 2
      TudlaAccounting.configuration.api_rate_limit_store = ActiveSupport::Cache::MemoryStore.new
      2.times { get routes.api_v1_organization_path, headers: headers }
      expect(response).to have_http_status(:ok)
      expect(response.headers.values_at("X-RateLimit-Limit", "X-RateLimit-Remaining")).to eq(%w[2 0])
      get routes.api_v1_organization_path, headers: headers
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("60")
      expect(json.dig("error", "code")).to eq("rate_limited")

      other_secret = TudlaAccounting::ApiToken.issue!(organization: organization, name: "Other", permissions: %w[read]).last
      get routes.api_v1_organization_path, headers: { "Authorization" => "Bearer #{other_secret}" }
      expect(response).to have_http_status(:ok)
      travel 1.minute
      get routes.api_v1_organization_path, headers: headers
      expect(response).to have_http_status(:ok)

      TudlaAccounting.configuration.api_rate_limit = nil
      5.times { get routes.api_v1_organization_path, headers: headers }
      expect(response.headers["X-RateLimit-Limit"]).to be_nil
    end

    it "names the permission each action needs, read by default" do
      controller = Class.new(TudlaAccounting::Api::V1::BaseController) { permits :post, only: %i[create] }
      expect(controller.api_permissions).to eq("create" => :post)
      expect { controller.permits(:delete_everything, only: :x) }.to raise_error(ArgumentError, "unknown permission :delete_everything")
    end

    context "with a token that can't read" do
      let(:permissions) { %w[record] }

      it "refuses" do
        get routes.api_v1_accounts_path, headers: headers
        expect(response).to have_http_status(:forbidden)
        expect(json.dig("error", "message")).to eq("This token can't read; issue one that can")
      end
    end
  end

  it "lists the accounts, a page at a time, and finds one by id or code" do
    data = api_get(routes.api_v1_accounts_path, per_page: 2)
    expect(data["data"].map { |row| row["code"] }).to eq(%w[1000 1100])
    expect(data["meta"]).to eq("page" => 1, "per_page" => 2, "total_count" => 6, "total_pages" => 3)
    expect(api_get(routes.api_v1_accounts_path, page: 3, per_page: 2)["data"].map { |row| row["code"] }).to eq(%w[4000 4010])
    expect(api_get(routes.api_v1_accounts_path, category: "income")["data"].map { |row| [ row["code"], row["parent_code"] ] }).to eq([ [ "4000", nil ], %w[4010 4000] ])
    expect(api_get(routes.api_v1_accounts_path, per_page: 1000)["meta"]["per_page"]).to eq(200)
    account("1000").update!(active: false)
    expect(api_get(routes.api_v1_accounts_path, active: "false")["data"].map { |row| row["code"] }).to eq(%w[1000])

    expect(api_get(routes.api_v1_account_path("1100"))["data"]).to include("code" => "1100", "name" => "Receivables", "category" => "asset", "role" => "receivable", "active" => true)
    expect(api_get(routes.api_v1_account_path(account("4010").id))["data"]).to include("code" => "4010", "parent_code" => "4000")
    get routes.api_v1_account_path("9999"), headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "lists entries with their lines, by status, dates, account and reference, and changes since a time" do
    TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department").dimension_values.create!(code: "SALES", name: "Sales")
    capital = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Capital", reference: "CAP",
                                                           transacted_at: Time.zone.local(2026, 3, 1).iso8601, idempotency_key: "cap-1",
                                                           details: [ { account_code: "1000", amount: "AUD 500.00" }, { account_code: "3000", amount: "AUD 500.00", description: "Owner", dimensions: { "DEPT" => "SALES" } } ])
    capital.post(capital.transacted_at)
    invoice = invoice!
    TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Draft",
                                                 transacted_at: Time.zone.local(2026, 4, 10).iso8601,
                                                 details: [ { account_code: "1000", amount: "AUD 1.00" }, { account_code: "3000", amount: "AUD 1.00" } ])

    entry = api_get(routes.api_v1_entry_path(capital))["data"]
    expect(entry).to include("id" => capital.id, "number" => "#1", "status" => "posted", "particulars" => "Capital", "reference" => "CAP", "currency" => "AUD",
                             "transacted_at" => "2026-03-01T00:00:00Z", "source" => nil, "idempotency_key" => "cap-1")
    expect(entry["lines"]).to eq([
      { "account_code" => "1000", "debit" => "500.00", "credit" => nil, "description" => nil, "tax_code" => nil, "tax_role" => nil, "foreign" => nil, "dimensions" => {} },
      { "account_code" => "3000", "debit" => nil, "credit" => "500.00", "description" => "Owner", "tax_code" => nil, "tax_role" => nil, "foreign" => nil, "dimensions" => { "DEPT" => "SALES" } }
    ])
    expect(api_get(routes.api_v1_entry_path(invoice.entry))["data"]).to include("source" => { "type" => "document", "id" => invoice.id })

    particulars = ->(**filters) { api_get(routes.api_v1_entries_path, **filters)["data"].map { |row| row["particulars"] } }
    expect(particulars.call).to eq([ "Capital", "Invoice INV-0001 – Northwind", "Draft" ])
    expect(particulars.call(status: "posted")).to eq([ "Capital", "Invoice INV-0001 – Northwind" ])
    expect(particulars.call(status: "draft")).to eq([ "Draft" ])
    expect(particulars.call(from: "2026-04-01", to: "2026-04-01")).to eq([ "Invoice INV-0001 – Northwind" ])
    expect(particulars.call(account: "4000")).to eq([ "Invoice INV-0001 – Northwind" ]) # its sub-accounts too
    expect(particulars.call(reference: "CAP")).to eq([ "Capital" ])
    expect(particulars.call(updated_since: 1.minute.from_now.iso8601)).to eq([])

    euro = TudlaAccounting::Account.create!(organization: organization, code: "1050", name: "Euro account", category: "asset", currency: "EUR")
    foreign = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Euros in",
                                                           transacted_at: Time.zone.local(2026, 4, 2).iso8601,
                                                           details: [ { account_code: euro.code, amount: "AUD 165.00", fx: { other_currency_amount: "EUR 100.00", fx_rate: "1.65" } },
                                                                      { account_code: "3000", amount: "AUD 165.00" } ])
    expect(api_get(routes.api_v1_entry_path(foreign))["data"]["lines"].first["foreign"]).to eq("currency" => "EUR", "amount" => "100.00", "rate" => "1.65")

    get routes.api_v1_entries_path, params: { from: "1 April" }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["error"]).to eq("code" => "invalid_request", "message" => "From must be an ISO 8601 date (YYYY-MM-DD)")
    get routes.api_v1_entries_path, params: { updated_since: "yesterday" }, headers: headers
    expect(json.dig("error", "message")).to eq("Updated_since must be an ISO 8601 time")
  end

  it "shows contacts, invoices with what is owed, payments with what they paid, tax codes and periods" do
    invoice = invoice!
    payment = TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 4, 10),
                                               amount_cents: 300_00, reference: "EFT 1", applications: [ { document: invoice, amount_cents: 200_00 } ])
    TudlaAccounting::Contact.create!(organization: organization, name: "Acme Supplies", kind: "supplier")

    expect(api_get(routes.api_v1_contacts_path, kind: "customer")["data"].map { |row| row["name"] }).to eq(%w[Northwind])
    expect(api_get(routes.api_v1_contacts_path, q: "supplies")["data"].map { |row| row["name"] }).to eq([ "Acme Supplies" ])
    expect(api_get(routes.api_v1_contacts_path, active: "true")["meta"]["total_count"]).to eq(2)
    expect(api_get(routes.api_v1_contact_path(northwind))["data"]).to include("name" => "Northwind", "kind" => "both", "email" => "ap@northwind.test", "payment_terms_days" => 30, "active" => true)

    document = api_get(routes.api_v1_document_path(invoice))["data"]
    expect(document).to include("kind" => "sales_invoice", "status" => "approved", "payment_status" => "part_paid", "number" => "INV-0001", "reference" => "PO 9",
                                "contact" => { "id" => northwind.id, "name" => "Northwind" }, "issued_on" => "2026-04-01", "due_on" => "2026-05-01", "currency" => "AUD",
                                "subtotal" => "250.00", "tax" => "25.00", "total" => "275.00", "amount_due" => "75.00", "entry_id" => invoice.entry_id)
    expect(document["lines"]).to eq([ { "description" => "Consulting", "quantity" => "2.5", "unit_price" => "100.00", "amount" => "250.00", "account_code" => "4010",
                                        "tax_code" => "GST", "tax" => "25.00" } ])
    numbers = ->(**filters) { api_get(routes.api_v1_documents_path, **filters)["data"].map { |row| row["number"] } }
    expect(numbers.call(kind: "sales_invoice", status: "approved", contact_id: northwind.id, from: "2026-04-01", to: "2026-04-30")).to eq(%w[INV-0001])
    expect(numbers.call(number: "INV-0001")).to eq(%w[INV-0001])
    expect(numbers.call(kind: "bill")).to eq([])
    expect(api_get(routes.api_v1_documents_path)["data"].first["amount_due"]).to eq("75.00")

    shown = api_get(routes.api_v1_payment_path(payment))["data"]
    expect(shown).to include("kind" => "received", "status" => "posted", "account_code" => "1000", "paid_on" => "2026-04-10", "amount" => "300.00", "unapplied" => "100.00", "reference" => "EFT 1")
    expect(shown["applied"]).to eq([ { "document_id" => invoice.id, "number" => "INV-0001", "entry_id" => invoice.entry_id, "amount" => "200.00",
                                       "applied_at" => "2026-04-10T00:00:00Z", "active" => true } ])
    expect(api_get(routes.api_v1_payments_path, kind: "received", status: "posted", contact_id: northwind.id, from: "2026-04-10", to: "2026-04-10")["meta"]["total_count"]).to eq(1)
    expect(api_get(routes.api_v1_payments_path, kind: "paid")["data"]).to eq([])

    expect(api_get(routes.api_v1_tax_codes_path)["data"]).to eq([ { "id" => gst.id, "code" => "GST", "name" => "GST", "kind" => "sales", "rate" => "0.1", "account_code" => "2200", "active" => true } ])
    periods = api_get(routes.api_v1_periods_path, per_page: 200)["data"]
    expect(periods.size).to eq(13)
    expect(periods.find { |period| period["kind"] == "year" }).to include("from_date" => "2026-01-01", "thru_date" => "2026-12-31", "closed" => false)
    expect(periods.find { |period| period["label"] == "Mar 2026" }).to include("from_date" => "2026-03-01", "thru_date" => "2026-03-31")
  end

  describe "reports" do
    it "lays each out as headings and rows, amounts as decimal strings" do
      invoice!
      months = TudlaAccounting::Period.where(organization: organization).where.not(ancestry: "/").order(:from_date).to_a
      april = months.fourth

      trial = api_get(routes.api_v1_report_path("trial_balance"), period_id: april.id)
      expect(trial["report"]).to eq("trial_balance")
      expect(trial["data"]["headings"]).to start_with("Code")
      expect(trial["data"]["rows"].last["total"]).to be(true)
      expect(trial["data"]["rows"].map { |row| row["cells"].first }).to include("1100", "4010")

      expect(api_get(routes.api_v1_report_path("profit_and_loss"), compare: "previous", period_id: april.id)["data"]["headings"].size).to be > 2
      expect(api_get(routes.api_v1_report_path("balance_sheet"))["data"]["rows"]).not_to be_empty
      receivables = api_get(routes.api_v1_report_path("receivables"), as_of: "2026-04-15")["data"]
      expect(receivables["rows"].first["cells"]).to include("Northwind", "275.00")
      expect(api_get(routes.api_v1_report_path("payables"))["data"]["rows"].map { |row| row["total"] }).to all(be(true))
      expect(api_get(routes.api_v1_report_path("tax"), from_id: april.id, thru_id: april.id, basis: "accrual")["data"]["rows"].first["cells"]).to include("GST")
      ledger = api_get(routes.api_v1_report_path("general_ledger"), from_id: april.id, thru_id: april.id, account: "4010")["data"]
      expect(ledger["rows"].map { |row| row["cells"] }.flatten).to include("Invoice INV-0001 – Northwind")

      get routes.api_v1_report_path("cash_flow"), headers: headers
      expect(json["error"]).to eq("code" => "invalid_request", "message" => "The cash flow statement needs the cash_account_codes setting")
      TudlaAccounting.configuration.cash_account_codes = %w[1000]
      expect(api_get(routes.api_v1_report_path("cash_flow"), method: "indirect")["data"]["rows"]).not_to be_empty

      get routes.api_v1_report_path("horoscope"), headers: headers
      expect(response).to have_http_status(:not_found)
      get routes.api_v1_report_path("trial_balance"), params: { period_id: 0 }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "says when the books have no periods yet" do
      secret = TudlaAccounting::ApiToken.issue!(organization: create(:organization), name: "New books", permissions: %w[read]).last
      %w[trial_balance tax].each do |report|
        get routes.api_v1_report_path(report), headers: { "Authorization" => "Bearer #{secret}" }
        expect(response).to have_http_status(:not_found)
        expect(json.dig("error", "code")).to eq("no_periods")
      end
    end
  end
end
