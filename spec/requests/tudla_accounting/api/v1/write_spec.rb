require "rails_helper"
require_relative "../../../../support/configuration"

RSpec.describe "JSON API: recording in the books", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %w[read record post] }
  let(:secret) { TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: permissions).last }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", payment_terms_days: 30) }
  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200")) }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1050", name: "Euro account", category: "asset", currency: "EUR" },
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "2200", name: "GST", category: "liability" }, { code: "3000", name: "Capital", category: "equity" },
      { code: "4000", name: "Sales", category: "income" }, { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
    gst
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def json = JSON.parse(response.body)

  def call(method, path, body = {}, key: nil)
    headers = { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" }
    headers["Idempotency-Key"] = key if key
    public_send(method, path, params: body.to_json, headers: headers)
    json if response.body.present?
  end

  describe "entries" do
    let(:sale) do
      { date: "2026-04-10", particulars: "Cash sale", reference: "S-1",
        lines: [ { account_code: "1000", debit: "110.00" }, { account_code: "4000", credit: "100", tax_code: "GST", description: "Widgets", dimensions: { "DEPT" => "SALES" } } ] }
    end

    before { TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department").dimension_values.create!(code: "SALES", name: "Sales") }

    it "records a draft from debits and credits, posts it, reverses it, as the token on the audit trail" do
      data = call(:post, routes.api_v1_entries_path, sale)["data"]
      expect(response).to have_http_status(:created)
      expect(data).to include("status" => "draft", "particulars" => "Cash sale", "reference" => "S-1", "transacted_at" => "2026-04-10T00:00:00Z")
      expect(data["lines"].map { |line| line.values_at("account_code", "debit", "credit", "tax_role") }).to eq([ [ "1000", "110.00", nil, nil ], [ "4000", nil, "100.00", "base" ], [ "2200", nil, "10.00", "tax" ] ])
      expect(data["lines"].second).to include("description" => "Widgets", "dimensions" => { "DEPT" => "SALES" })

      posted = call(:post, routes.post_api_v1_entry_path(data["id"]))["data"]
      expect(posted).to include("status" => "posted", "number" => "#1")
      call(:post, routes.post_api_v1_entry_path(data["id"]))
      expect(json["error"]).to eq("code" => "invalid_request", "message" => "The entry is posted already")

      reversal = call(:post, routes.reverse_api_v1_entry_path(data["id"]), { on: "2026-04-12" })["data"]
      expect(response).to have_http_status(:created)
      expect(reversal).to include("particulars" => "Reversal of: Cash sale", "related_entry_id" => data["id"], "transacted_at" => "2026-04-12T00:00:00Z")
      expect(call(:post, routes.reverse_api_v1_entry_path(data["id"]))["error"]["message"]).to eq("This entry has already been reversed")

      events = TudlaAccounting::AuditEvent.where(organization: organization, action: %w[entry.posted entry.reversed])
      expect(events.map(&:actor_label).uniq).to eq([ "API token Shop" ])
      expect(events.first.actor).to eq(TudlaAccounting::ApiToken.sole)
    end

    it "posts as it records, all or nothing, and takes amounts in another currency" do
      inclusive = sale.merge(post: true, date: "2026-04-10T14:30:00+10:00", tax_inclusive: true,
                             lines: [ sale[:lines].first, sale[:lines].last.merge(credit: "110") ])
      data = call(:post, routes.api_v1_entries_path, inclusive)["data"]
      expect(data).to include("status" => "posted", "transacted_at" => "2026-04-10T04:30:00Z")
      expect(data["lines"].map { |line| line["credit"] }).to eq([ nil, "100.00", "10.00" ])

      year = TudlaAccounting::Period.roots.find_by!(organization: organization)
      year.children.order(:from_date).first(3).each(&:close!)
      call(:post, routes.api_v1_entries_path, sale.merge(post: true, date: "2026-03-10"))
      expect(json["error"]).to eq("code" => "invalid_request", "message" => "The period for the posted date is closed")
      expect(TudlaAccounting::Entry.count).to eq(1)

      foreign = call(:post, routes.api_v1_entries_path, { date: "2026-04-11", particulars: "Euros", lines: [
        { account_code: "1050", debit: "165.00", foreign: { currency: "EUR", amount: "100", rate: "1.65" } }, { account_code: "3000", credit: "165.00" }
      ] })["data"]
      expect(foreign["lines"].first["foreign"]).to eq("currency" => "EUR", "amount" => "100.00", "rate" => "1.65")
    end

    it "returns the entry an earlier request with the same Idempotency-Key made" do
      first = call(:post, routes.api_v1_entries_path, sale, key: "order-77")["data"]
      again = call(:post, routes.api_v1_entries_path, sale.merge(particulars: "Different"), key: "order-77")["data"]
      expect(response).to have_http_status(:ok)
      expect(response.headers["Idempotent-Replayed"]).to eq("true")
      expect(again).to eq(first)
      expect(TudlaAccounting::Entry.sole.idempotency_key).to eq("api:order-77")
      call(:post, routes.api_v1_entries_path, sale, key: "x" * 201)
      expect(json.dig("error", "message")).to eq("Idempotency-Key must be at most 200 characters")
    end

    it "says what's wrong with what was sent" do
      problems = {
        { lines: [] } => "Lines must be a list of at least two lines",
        sale.except(:particulars) => "Particulars is missing",
        sale.except(:date) => "Date is missing",
        sale.merge(date: "10/04/2026") => "Date must be an ISO 8601 date (YYYY-MM-DD) or time",
        sale.merge(lines: [ "x", "y" ]) => "Line 1 must be an object",
        sale.merge(lines: [ { account_code: "9999", debit: "1" }, sale[:lines].last ]) => "Line 1: there is no account 9999",
        sale.merge(lines: [ { account_code: "1000", debit: "1", credit: "1" }, sale[:lines].last ]) => "Line 1 needs a debit or a credit, not both",
        sale.merge(lines: [ { account_code: "1000", debit: "lots" }, sale[:lines].last ]) => "Line 1's debit must be a decimal number, such as \"1234.50\"",
        sale.merge(lines: [ { account_code: "1000", debit: "-5" }, sale[:lines].last ]) => "Line 1's amount must be more than zero",
        sale.merge(lines: [ { account_code: "1000", debit: "10.005" }, sale[:lines].last ]) => "Line 1's debit: 10.005 has too many decimal places for AUD, which has 2",
        sale.merge(lines: [ { account_code: "1050", debit: "1", foreign: "EUR" }, sale[:lines].last ]) => "Line 1's foreign must be an object with currency, amount and rate",
        sale.merge(lines: [ { account_code: "1050", debit: "1", foreign: { currency: "XYZ" } }, sale[:lines].last ]) => "Line 1's foreign currency \"XYZ\" isn't known",
        sale.merge(lines: [ { account_code: "1000", debit: "5" }, { account_code: "4000", credit: "4" } ]) => "The credit and debit amounts are not equal"
      }
      problems.each do |sent, message|
        call(:post, routes.api_v1_entries_path, sent)
        expect(response).to have_http_status(:unprocessable_content), sent.inspect
        expect(json.dig("error", "message")).to eq(message), sent.inspect
      end
      expect(TudlaAccounting::Entry.count).to eq(0)
    end

    it "deletes drafts only" do
      draft = call(:post, routes.api_v1_entries_path, sale)["data"]
      posted = call(:post, routes.api_v1_entries_path, sale.merge(post: true))["data"]
      call(:delete, routes.api_v1_entry_path(posted["id"]))
      expect(json.dig("error", "message")).to eq("Only a draft can be deleted; reverse a posted entry instead")
      call(:delete, routes.api_v1_entry_path(draft["id"]))
      expect(response).to have_http_status(:no_content)
      expect(TudlaAccounting::Entry.pluck(:id)).to eq([ posted["id"] ])
    end
  end

  describe "contacts" do
    it "adds and changes them, saying what's wrong" do
      data = call(:post, routes.api_v1_contacts_path, { name: "Globex", kind: "both", email: "ap@globex.test", payment_terms_days: 14,
                                                      default_account_code: "4000", default_tax_code: "GST" })["data"]
      expect(response).to have_http_status(:created)
      expect(data).to include("name" => "Globex", "kind" => "both", "payment_terms_days" => 14, "default_account_code" => "4000", "default_tax_code" => "GST")

      changed = call(:patch, routes.api_v1_contact_path(data["id"]), { phone: "02 9999 0000", default_tax_code: nil, active: false })["data"]
      expect(changed).to include("phone" => "02 9999 0000", "default_tax_code" => nil, "default_account_code" => "4000", "active" => false, "email" => "ap@globex.test")

      call(:post, routes.api_v1_contacts_path, { name: "", email: "nope" })
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to include("code" => "invalid", "details" => { "name" => [ "can't be blank" ], "email" => [ "is invalid" ] })
      call(:post, routes.api_v1_contacts_path, { name: "X", default_account_code: "9999" })
      expect(json.dig("error", "message")).to eq("Default_account_code: there is no account 9999")
      call(:post, routes.api_v1_contacts_path, { name: "X", default_tax_code: "VAT" })
      expect(json.dig("error", "message")).to eq("Default_tax_code: there is no tax code VAT")
      expect(TudlaAccounting::AuditEvent.where(action: "contact.created").pluck(:actor_label)).to eq([ "API token Shop" ])
    end
  end

  describe "invoices and bills" do
    let(:invoice) do
      { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-04-01", reference: "PO 9",
        lines: [ { description: "Consulting", quantity: "2.5", unit_price: "100", account_code: "4000", tax_code: "GST" } ] }
    end

    it "drafts one with the contact's terms, changes it, approves it, voids it" do
      data = call(:post, routes.api_v1_documents_path, invoice)["data"]
      expect(response).to have_http_status(:created)
      expect(data).to include("status" => "draft", "number" => nil, "due_on" => "2026-05-01", "total" => "275.00")

      changed = call(:patch, routes.api_v1_document_path(data["id"]), { due_on: "2026-04-20", lines: [ { description: "Design", unit_price: "50", account_code: "4000" } ] })["data"]
      expect(changed).to include("due_on" => "2026-04-20", "reference" => "PO 9", "total" => "50.00")
      expect(changed["lines"]).to eq([ { "description" => "Design", "quantity" => "1.0", "unit_price" => "50.00", "amount" => "50.00", "account_code" => "4000", "tax_code" => nil, "tax" => "0.00", "dimensions" => {} } ])
      expect(call(:patch, routes.api_v1_document_path(data["id"]), { notes: "Thanks" })["data"]["lines"].size).to eq(1)

      approved = call(:post, routes.approve_api_v1_document_path(data["id"]))["data"]
      expect(approved).to include("status" => "approved", "number" => "INV-0001", "payment_status" => "unpaid", "amount_due" => "50.00")
      call(:patch, routes.api_v1_document_path(data["id"]), { notes: "x" })
      expect(json.dig("error", "message")).to eq("Only a draft can be changed; void it and issue another")
      call(:delete, routes.api_v1_document_path(data["id"]))
      expect(json.dig("error", "message")).to eq("Only a draft can be deleted; void an approved document instead")

      call(:post, routes.void_api_v1_document_path(data["id"]), { reason: "Wrong" })
      expect(json.dig("error", "message")).to eq("On is missing")
      voided = call(:post, routes.void_api_v1_document_path(data["id"]), { on: "2026-04-15", reason: "Wrong customer" })["data"]
      expect(voided).to include("status" => "void", "voided_on" => "2026-04-15", "void_reason" => "Wrong customer")
      expect(TudlaAccounting::AuditEvent.where(action: %w[document.approved document.voided]).pluck(:actor_label).uniq).to eq([ "API token Shop" ])
    end

    it "approves as it drafts, all or nothing, once per Idempotency-Key, and credits an invoice" do
      first = call(:post, routes.api_v1_documents_path, invoice.merge(approve: true), key: "inv-1")["data"]
      expect(first).to include("status" => "approved", "number" => "INV-0001")
      expect(call(:post, routes.api_v1_documents_path, invoice.merge(approve: true), key: "inv-1")["data"]["id"]).to eq(first["id"])
      expect(response.headers["Idempotent-Replayed"]).to eq("true")

      credit = call(:post, routes.api_v1_documents_path, { kind: "sales_credit", contact_id: northwind.id, issued_on: "2026-04-05", credited_document_id: first["id"], approve: true,
                                                           lines: [ { description: "Discount", unit_price: "25", account_code: "4000" } ] })["data"]
      expect(credit).to include("number" => "CN-0001", "credited_document_id" => first["id"], "payment_status" => "paid")
      expect(call(:get, routes.api_v1_document_path(first["id"]))["data"]["amount_due"]).to eq("250.00")

      TudlaAccounting::Period.roots.find_by!(organization: organization).children.order(:from_date).first(3).each(&:close!)
      call(:post, routes.api_v1_documents_path, invoice.merge(issued_on: "2026-03-01", approve: true))
      expect(json.dig("error", "message")).to eq("The period for the posted date is closed")
      expect(TudlaAccounting::Document.count).to eq(2)
    end

    it "deletes a draft, and says what's wrong" do
      draft = call(:post, routes.api_v1_documents_path, invoice)["data"]
      call(:delete, routes.api_v1_document_path(draft["id"]))
      expect(response).to have_http_status(:no_content)

      { invoice.merge(kind: "quote") => "Kind must be one of sales_invoice, sales_credit, bill, supplier_credit",
        invoice.except(:contact_id) => "Contact_id is missing",
        invoice.except(:issued_on) => "Issued on can't be blank",
        invoice.merge(lines: "Consulting") => "Lines must be a list",
        invoice.merge(lines: [ 1 ]) => "Line 1 must be an object",
        invoice.merge(lines: [ { description: "x", unit_price: "1", account_code: "4000", tax_code: "VAT" } ]) => "Line 1: there is no tax code VAT",
        invoice.merge(lines: [ { description: "x", quantity: "two", unit_price: "1", account_code: "4000" } ]) => "Line 1's quantity must be a decimal number",
        invoice.merge(lines: [ { description: "x", account_code: "4000" } ]) => "Line 1's unit_price is missing",
        invoice.merge(lines: []) => "Add at least one line" }.each do |sent, message|
        call(:post, routes.api_v1_documents_path, sent)
        expect(response).to have_http_status(:unprocessable_content), sent.inspect
        expect(json.dig("error", "message")).to start_with(message), sent.inspect
      end
    end
  end

  describe "payments" do
    it "records one applied to invoices, once per Idempotency-Key, and voids it" do
      invoice = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 4, 1),
                                                  lines_attributes: [ { description: "Work", unit_price_cents: 100_00, account: account("4000") } ]).approve!
      sent = { kind: "received", contact_id: northwind.id, account_code: "1000", paid_on: "2026-04-10", amount: "150.00", reference: "EFT 1",
               applications: [ { document_id: invoice.id, amount: "100.00" } ] }
      data = call(:post, routes.api_v1_payments_path, sent, key: "pay-1")["data"]
      expect(response).to have_http_status(:created)
      expect(data).to include("kind" => "received", "amount" => "150.00", "unapplied" => "50.00", "reference" => "EFT 1")
      expect(data["applied"].map { |row| row.values_at("number", "amount") }).to eq([ %w[INV-0001 100.00] ])
      expect(call(:post, routes.api_v1_payments_path, sent, key: "pay-1")["data"]["id"]).to eq(data["id"])
      expect(TudlaAccounting::Payment.count).to eq(1)

      { sent.merge(amount: "50") => "$100.00 is more than is owed on INV-0001",
        sent.merge(applications: [ "x" ]) => "Application 1 must be an object with document_id and amount",
        sent.except(:paid_on) => "Paid_on is missing",
        sent.merge(account_code: "9") => "Account_code: there is no account 9",
        sent.merge(kind: "gift", applications: []) => "Kind is not included in the list" }.each do |bad, message|
        call(:post, routes.api_v1_payments_path, bad)
        expect(json.dig("error", "message")).to eq(message), bad.inspect
      end

      call(:post, routes.void_api_v1_payment_path(data["id"]), { reason: "x" })
      expect(json.dig("error", "message")).to eq("On is missing")
      voided = call(:post, routes.void_api_v1_payment_path(data["id"]), { on: "2026-04-15", reason: "Bounced" })["data"]
      expect(voided).to include("status" => "void", "void_reason" => "Bounced")
      expect(invoice.reload.amount_due.cents).to eq(100_00)
      expect(TudlaAccounting::AuditEvent.where(action: %w[payment.recorded payment.voided]).pluck(:actor_label).uniq).to eq([ "API token Shop" ])
    end
  end

  describe "two requests with the same Idempotency-Key at once" do
    # The second's check for an earlier one ran before the first had committed.
    def race(controller)
      checks = 0
      allow_any_instance_of(controller).to receive(:replay).and_wrap_original do |original, *args|
        (checks += 1) == 1 ? nil : original.call(*args)
      end
    end

    it "return what the first made, the database refusing the second" do
      invoice = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 4, 1), idempotency_key: "api:doc",
                                                  lines_attributes: [ { description: "Work", unit_price_cents: 100_00, account: account("4000") } ])
      race(TudlaAccounting::Api::V1::DocumentsController)
      data = call(:post, routes.api_v1_documents_path, { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-04-01",
                                                         lines: [ { description: "Work", unit_price: "100", account_code: "4000" } ] }, key: "doc")["data"]
      expect(response).to have_http_status(:ok)
      expect(data["id"]).to eq(invoice.id)

      payment = TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 4, 2),
                                                 amount_cents: 10_00, idempotency_key: "api:pay")
      race(TudlaAccounting::Api::V1::PaymentsController)
      data = call(:post, routes.api_v1_payments_path, { kind: "received", contact_id: northwind.id, account_code: "1000", paid_on: "2026-04-02", amount: "10" }, key: "pay")["data"]
      expect(data["id"]).to eq(payment.id)
      expect([ TudlaAccounting::Document.count, TudlaAccounting::Payment.count ]).to eq([ 1, 1 ])
    end
  end

  describe "permissions" do
    let(:permissions) { %w[read record] }

    it "lets a token record but not post" do
      sale = { date: "2026-04-10", particulars: "Sale", lines: [ { account_code: "1000", debit: "1" }, { account_code: "4000", credit: "1" } ] }
      call(:post, routes.api_v1_entries_path, sale.merge(post: true))
      expect(response).to have_http_status(:forbidden)
      expect(json.dig("error", "message")).to eq("This token can't post; issue one that can")
      draft = call(:post, routes.api_v1_entries_path, sale)["data"]
      call(:post, routes.post_api_v1_entry_path(draft["id"]))
      expect(response).to have_http_status(:forbidden)
      call(:post, routes.api_v1_documents_path, { kind: "sales_invoice", approve: true })
      expect(response).to have_http_status(:forbidden)
      call(:post, routes.api_v1_payments_path, {})
      expect(response).to have_http_status(:forbidden)
      expect(TudlaAccounting::Entry.count).to eq(1)
    end
  end

  describe "with a read-only token" do
    let(:permissions) { %w[read] }

    it "records nothing" do
      call(:post, routes.api_v1_contacts_path, { name: "Globex" })
      expect(response).to have_http_status(:forbidden)
      expect(json.dig("error", "message")).to eq("This token can't record; issue one that can")
    end
  end
end
