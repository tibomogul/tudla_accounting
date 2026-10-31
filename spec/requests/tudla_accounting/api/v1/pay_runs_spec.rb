require "rails_helper"
require_relative "../../../../support/configuration"

RSpec.describe "JSON API: the supplier pay run", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %w[read record post] }
  let(:secret) { TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: permissions).last }
  let(:cloudware) { TudlaAccounting::Contact.create!(organization: organization, name: "Cloudware", kind: "supplier", email: "ar@cloudware.test") }
  let(:initech) { TudlaAccounting::Contact.create!(organization: organization, name: "Initech", kind: "supplier") }
  let(:hosting) { bill(cloudware, 110_00, due: Date.new(2026, 4, 20)) }
  let(:licences) { bill(cloudware, 50_00, due: Date.new(2026, 5, 30)) }
  let(:paper) { bill(initech, 30_00, due: Date.new(2026, 4, 10)) }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1050", name: "Euro account", category: "asset", currency: "EUR" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
    [ hosting, licences, paper ]
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def json = JSON.parse(response.body)

  def bill(supplier, cents, due:)
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 4, 1), due_on: due,
                                      lines_attributes: [ { description: "Supplies", unit_price_cents: cents, account: account("6000") } ]).approve!
  end

  def call(method, path, body = {}, key: nil)
    headers = { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" }
    headers["Idempotency-Key"] = key if key
    public_send(method, path, params: (body.to_json unless method == :get), headers: headers)
    json if response.body.present?
  end

  it "lists the bills due from an account, by supplier, due by a date or one supplier's" do
    data = call(:get, routes.api_v1_pay_run_path(account_code: "1000", due_by: "2026-04-30"))["data"]
    expect(data).to include("account_code" => "1000", "currency" => "AUD")
    expect(data["bills"].map { |bill| bill.values_at("document_id", "due_on", "amount_due") }).to eq([ [ hosting.id, "2026-04-20", "110.00" ], [ paper.id, "2026-04-10", "30.00" ] ])
    expect(data["bills"].first).to include("number" => hosting.number_label, "contact" => { "id" => cloudware.id, "name" => "Cloudware" }, "total" => "110.00")

    expect(call(:get, routes.api_v1_pay_run_path(account_code: "1000", contact_id: cloudware.id))["data"]["bills"].map { |bill| bill["document_id"] }).to eq([ hosting.id, licences.id ])
    expect(call(:get, routes.api_v1_pay_run_path(account_code: "1050"))["data"]).to include("currency" => "EUR", "bills" => [])
    call(:get, routes.api_v1_pay_run_path)
    expect(json.dig("error", "message")).to eq("Account_code is missing")
  end

  it "pays a batch, one payment per supplier, emailing their notices, once per Idempotency-Key" do
    sent = { account_code: "1000", paid_on: "2026-04-15", reference: "Pay run", email: true,
             bills: [ { document_id: hosting.id }, { document_id: licences.id, amount: "20" }, { document_id: paper.id } ] }
    data = call(:post, routes.api_v1_pay_runs_path, sent, key: "run-1")["data"]
    expect(response).to have_http_status(:created)
    expect(data["payments"].map { |payment| payment.values_at("kind", "amount", "reference") }).to eq([ [ "paid", "130.00", "Pay run" ], [ "paid", "30.00", "Pay run" ] ])
    expect(data["payments"].map { |payment| payment.dig("contact", "name") }).to eq(%w[Cloudware Initech])
    cloudware_payment, initech_payment = TudlaAccounting::Payment.order(:id).to_a
    expect(data).to include("emailed_ids" => [ cloudware_payment.id ], "no_address_ids" => [ initech_payment.id ])
    expect([ hosting, licences, paper ].map { |document| document.reload.amount_due.cents }).to eq([ 0, 30_00, 0 ])

    again = call(:post, routes.api_v1_pay_runs_path, sent, key: "run-1")["data"]
    expect(response).to have_http_status(:ok)
    expect(response.headers["Idempotent-Replayed"]).to eq("true")
    expect(again).to include("payments" => data["payments"], "emailed_ids" => [ cloudware_payment.id ], "no_address_ids" => [])
    expect(TudlaAccounting::Payment.count).to eq(2)
  end

  it "returns what the first made when a second run with its key raced it" do
    TudlaAccounting::PayRun.call(organization: organization, account: account("1000"), paid_on: Date.new(2026, 4, 15), bills: [ { document: paper, amount_cents: 10_00 } ],
                                 idempotency_key: "api:run-2:pay_run")
    checks = 0
    allow_any_instance_of(TudlaAccounting::Api::V1::PayRunsController).to receive(:made).and_wrap_original do |original, *args|
      (checks += 1) == 1 ? [] : original.call(*args)
    end
    data = call(:post, routes.api_v1_pay_runs_path, { account_code: "1000", paid_on: "2026-04-15", bills: [ { document_id: paper.id } ] }, key: "run-2")["data"]
    expect(response).to have_http_status(:ok)
    expect(data["payments"].map { |payment| payment["amount"] }).to eq([ "10.00" ])
    expect(TudlaAccounting::Payment.count).to eq(1)
  end

  it "says what's wrong, paying nothing" do
    sent = { account_code: "1000", paid_on: "2026-04-15", bills: [ { document_id: paper.id } ] }
    { sent.merge(bills: "all") => "Bills must be a list",
      sent.merge(bills: [ 1 ]) => "Bill 1 must be an object with document_id, and amount if not all that is owed",
      sent.merge(bills: [ { document_id: paper.id, amount: "lots" } ]) => "Bill 1's amount must be a decimal number",
      sent.merge(bills: []) => "Choose at least one bill to pay",
      sent.except(:paid_on) => "Paid_on is missing",
      sent.merge(account_code: "1050") => "Initech: " }.each do |body, message|
      call(:post, routes.api_v1_pay_runs_path, body)
      expect(response).to have_http_status(:unprocessable_content), body.inspect
      expect(json.dig("error", "message")).to start_with(message), body.inspect
    end
    invoice = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: TudlaAccounting::Contact.create!(organization: organization, name: "Northwind"),
                                                issued_on: Date.new(2026, 4, 1), lines_attributes: [ { description: "Work", unit_price_cents: 1_00, account: account("6000") } ])
    call(:post, routes.api_v1_pay_runs_path, sent.merge(bills: [ { document_id: invoice.id } ]))
    expect(response).to have_http_status(:not_found)
    expect(TudlaAccounting::Payment.count).to eq(0)
  end

  describe "with a token that can't post" do
    let(:permissions) { %w[read record] }

    it "lists the bills but pays none" do
      expect(call(:get, routes.api_v1_pay_run_path(account_code: "1000"))["data"]["bills"].size).to eq(3)
      call(:post, routes.api_v1_pay_runs_path, { account_code: "1000", paid_on: "2026-04-15", bills: [ { document_id: paper.id } ] })
      expect(response).to have_http_status(:forbidden)
    end
  end
end
