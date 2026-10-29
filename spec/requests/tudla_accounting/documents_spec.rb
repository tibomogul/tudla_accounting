require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Invoices and bills", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post] }
  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200")) }
  let(:northwind) do
    TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", payment_terms_days: 14, address: "1 Main St\nSydney",
                                     tax_number: "51 824 753 556", default_account: account("4000"), default_tax_code: gst)
  end

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }, { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
    northwind
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def invoice_params(**extra)
    { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-04-10", due_on: "2026-04-24", reference: "PO 9",
      notes: "Pay to BSB 000-000", lines: { "0" => { description: "Consulting", quantity: "3", unit_price: "1,000.00", account_id: account("4000").id, tax_code_id: gst.id },
                                             "1" => { description: "", quantity: "1", unit_price: "", account_id: "" } } }.merge(extra)
  end

  def numbers = css_select("tr[data-document-row] td:first-child a").map(&:text)

  it "drafts an invoice, edits it, approves it, prints it, and lists it as awaiting payment" do
    get routes.new_document_path(kind: "sales_invoice", contact_id: northwind.id)
    expect(response).to have_http_status(:ok)
    expect(css_select("input[name='document[due_on]']").first["value"]).to eq("2026-04-29")
    expect(css_select("select[name='document[lines][0][account_id]'] option[selected]").map(&:text)).to eq([ "4000 - Sales" ])
    expect(css_select("select[name='document[lines][0][account_id]'] option").map(&:text)).not_to include("1100 - Receivables")
    expect(css_select("select[name='document[contact_id]'] option").map(&:text)).to eq([ "Choose a customer", "Northwind" ])

    post routes.documents_path, params: { document: invoice_params }
    document = TudlaAccounting::Document.last
    expect(response).to redirect_to(routes.document_path(document))
    expect(document).to have_attributes(status: "draft", total_cents: 3_300_00, lines: [ have_attributes(description: "Consulting", unit_price_cents: 1_000_00) ])
    follow_redirect!
    expect(css_select("h1").first.text).to eq("Draft invoice")
    expect(css_select("[data-document]").first.text.squish).to include("Acme", "To Northwind", "1 Main St", "51 824 753 556", "Consulting", "3,300.00", "Your referencePO 9", "Pay to BSB")

    get routes.edit_document_path(document)
    expect(css_select("input[name='document[lines][0][unit_price]']").first["value"]).to eq("1000.00")
    patch routes.document_path(document), params: { document: invoice_params(lines: { "0" => { id: document.lines.first.id, description: "Consulting", quantity: "2.5", unit_price: "1000",
                                                                                             account_id: account("4000").id, tax_code_id: gst.id } }), approve: "1" }
    expect(response).to redirect_to(routes.document_path(document))
    expect(flash[:notice]).to eq("Invoice INV-0001 approved and posted.")
    expect(document.reload).to have_attributes(status: "approved", total_cents: 2_750_00)

    get routes.edit_document_path(document)
    expect(response).to redirect_to(routes.document_path(document))
    patch routes.document_path(document), params: { document: { reference: "x" } }
    expect(flash[:alert]).to eq("An approved document can't be changed; void it and issue another.")

    get routes.document_path(document)
    expect(css_select("[data-document] h2").first.text).to eq("Invoice")
    expect(response.body).to include("Posted as", "Awaiting payment", "Credit note")
    get routes.entry_path(document.entry)
    expect(response.body).to include("Posted for", "Invoice INV-0001")

    get routes.sales_documents_path
    expect(numbers).to eq([ "INV-0001" ])
    expect(css_select("tfoot").first.text.squish).to include("2,750.00")
    get routes.contact_path(northwind)
    expect(css_select("[data-documents]").first.text.squish).to include("Invoice INV-0001", "2,750.00", "Awaiting payment")
    expect(css_select("[data-open=receivable] a[href='#{routes.document_path(document)}']").map(&:text)).to eq([ "Invoice INV-0001" ])
    get routes.activity_path(kind: "document")
    expect(css_select("table").first.text.squish).to include("Drafted an invoice for Northwind", "Changed an invoice for Northwind: tax, total, subtotal", "Approved Invoice INV-0001")
  end

  it "says what's wrong with a draft and keeps what was typed" do
    post routes.documents_path, params: { document: invoice_params(due_on: "2026-04-01", lines: { "0" => { description: "Consulting", unit_price: "lots", account_id: account("4000").id } }) }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Line 1: lots isn&#39;t an amount")

    post routes.documents_path, params: { document: invoice_params(due_on: "2026-04-01") }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Due on must be on or after the date")
    expect(css_select("input[name='document[reference]']").first["value"]).to eq("PO 9")

    TudlaAccounting::Period.leaf_periods_for_date(organization, Time.zone.local(2026, 4, 10)).first.tap do |april|
      april.parent.children.order(:from_date).first(4).each(&:close!)
    end
    post routes.documents_path, params: { document: invoice_params, approve: "1" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("It was saved as a draft but not approved")
    expect(TudlaAccounting::Document.sole).to have_attributes(status: "draft", number: nil, entry_id: nil)
    expect(TudlaAccounting::Entry.count).to eq(0)
  end

  it "totals what is owed less credits to apply, in the same queries however many documents are listed" do
    issue = lambda do |kind, cents|
      TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: northwind, issued_on: Date.new(2026, 4, 1), due_on: Date.new(2026, 4, 10),
                                        lines_attributes: [ { description: "Consulting", quantity: 1, unit_price_cents: cents, account: account("4000"), tax_code: gst } ]).approve!
    end
    queries = lambda do
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get routes.sales_documents_path }
      count
    end
    owed = -> { css_select("tr.font-semibold").map { |row| row.text.squish }.find { |text| text.start_with?("Owed by customers") } }

    issue.call("sales_invoice", 100_00)
    issue.call("sales_credit", 20_00) # nothing to apply it to: a credit to apply
    few = queries.call
    expect(owed.call).to end_with(")88.00")

    3.times { issue.call("sales_invoice", 100_00) }
    expect(queries.call).to eq(few)
    expect(owed.call).to end_with(")418.00")
  end

  it "credits an invoice from its page, applying the credit note to it, and voids them" do
    invoice = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 4, 1), due_on: Date.new(2026, 4, 30),
                                                lines_attributes: [ { description: "Consulting", quantity: 1, unit_price_cents: 100_00, account: account("4000"), tax_code: gst } ]).approve!
    get routes.sales_documents_path(status: "overdue")
    expect(numbers).to eq([])

    get routes.new_document_path(credit: invoice.id)
    expect(css_select("h1").first.text).to eq("New credit note")
    expect(css_select("select[name='document[credited_document_id]'] option[selected]").map(&:text)).to eq([ "INV-0001 – Northwind ($110.00 due)" ])
    expect(css_select("input[name='document[lines][0][description]']").first["value"]).to eq("Consulting")

    post routes.documents_path, params: { document: { kind: "sales_credit", contact_id: northwind.id, issued_on: "2026-04-12", credited_document_id: invoice.id,
                                                      lines: { "0" => { description: "Discount", quantity: "1", unit_price: "40", account_id: account("4000").id, tax_code_id: gst.id } } } }
    credit = TudlaAccounting::Document.find_by!(kind: "sales_credit")
    post routes.approve_document_path(credit)
    expect(flash[:notice]).to eq("Credit note CN-0001 approved and posted.")

    get routes.document_path(invoice)
    expect(css_select("[data-document] tfoot").first.text.squish).to include("Paid or credited(44.00)", "Amount due66.00")
    expect(response.body).to include("Part paid", "CN-0001")
    expect(css_select("a[href='#{routes.document_path(credit)}']").map(&:text)).to include("Credit note CN-0001")
    get routes.document_path(credit)
    expect(response.body).to include("Applied to", "INV-0001", "Credits")
    expect(css_select("a[href='#{routes.document_path(invoice)}']").map(&:text)).to include("Invoice INV-0001")

    { "part_paid" => [ "INV-0001" ], "paid" => [ "CN-0001" ], "unpaid" => [], "draft" => [], "void" => [] }.each do |status, expected|
      get routes.sales_documents_path(status: status)
      expect(numbers).to eq(expected), status
    end
    travel_to Time.zone.local(2026, 5, 4, 9) do
      get routes.sales_documents_path(status: "overdue")
      expect(numbers).to eq([ "INV-0001" ])
      expect(css_select("tr[data-document-row]").first.text).to include("Overdue")
    end
    get routes.sales_documents_path(kind: "sales_credit")
    expect(numbers).to eq([ "CN-0001" ])
    get routes.sales_documents_path(q: "north")
    expect(numbers).to eq(%w[CN-0001 INV-0001])
    expect(css_select("tfoot").first.text.squish).to include("66.00")
    get routes.sales_documents_path(format: :csv, q: "INV")
    expect(response.body.lines.map(&:chomp)).to eq([ "Kind,Number,Date,Contact,Reference,Due,Subtotal,Tax,Total,Due now,Status,Currency,Due now (AUD)",
                                                            "Invoice,INV-0001,2026-04-01,Northwind,,2026-04-30,100.00,10.00,110.00,66.00,Part paid,AUD,66.00" ])

    post routes.void_document_path(invoice), params: { on: "2026-04-15", reason: "Wrong" }
    expect(flash[:alert]).to eq("It wasn't voided: reverse the payments against it first.")
    post routes.void_document_path(credit), params: { on: "bad", reason: "Wrong" }
    expect(flash[:alert]).to start_with("It wasn't voided: ")
    post routes.void_document_path(credit), params: { on: "2026-04-15", reason: "Wrong amount" }
    expect(flash[:notice]).to eq("Credit note CN-0001 voided: its entry is reversed on 15 Apr 2026.")
    get routes.document_path(credit)
    expect(response.body).to include("Voided 15 Apr 2026", "Wrong amount", "(taken off)")
    get routes.sales_documents_path(status: "void")
    expect(numbers).to eq([ "CN-0001" ])

    get routes.activity_path(kind: "document")
    expect(response.body).to include("Approved", "Voided", "Wrong amount")
  end

  it "keeps bills apart, and deletes drafts" do
    supplier = TudlaAccounting::Contact.create!(organization: organization, name: "Acme Supplies", kind: "supplier")
    get routes.new_document_path(kind: "bill")
    expect(css_select("select[name='document[contact_id]'] option").map(&:text)).to eq([ "Choose a supplier", "Acme Supplies", "Northwind" ])
    expect(css_select("label[for='document_reference']").first.text).to eq("Supplier's invoice number")

    post routes.documents_path, params: { document: { kind: "bill", contact_id: supplier.id, issued_on: "2026-04-02", reference: "S-1", notes: "Check the hours",
                                                      lines: { "0" => { description: "Paper", quantity: "", unit_price: "55", account_id: account("6000").id } } } }
    bill = TudlaAccounting::Document.find_by!(kind: "bill")
    get routes.purchase_documents_path
    expect(numbers).to eq([ "Draft" ])
    get routes.sales_documents_path
    expect(response.body).to include("No invoices yet.")
    get routes.document_path(bill)
    expect(response.body).to include("Draft bill", "Check the hours")

    delete routes.document_path(bill)
    expect(response).to redirect_to(routes.purchase_documents_path)
    expect(TudlaAccounting::Document.count).to eq(0)
    get routes.activity_path(kind: "document")
    expect(response.body).to include("Deleted a bill for Acme Supplies")

    approved = TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 4, 2),
                                                 lines_attributes: [ { description: "Paper", unit_price_cents: 55_00, account: account("6000") } ]).approve!
    delete routes.document_path(approved)
    expect(flash[:alert]).to eq("Only a draft can be deleted; void an approved document instead")
    post routes.approve_document_path(approved)
    expect(flash[:alert]).to eq("It wasn't approved: only a draft can be approved.")
    get routes.purchase_documents_path
    expect(response.body).to include("Owed to suppliers", "55.00")
  end

  context "with permission to record but not post" do
    let(:permissions) { %i[read record] }

    it "saves drafts but doesn't approve or void them" do
      post routes.documents_path, params: { document: invoice_params, approve: "1" }
      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("You can save drafts but not approve them")
      post routes.documents_path, params: { document: invoice_params }
      document = TudlaAccounting::Document.last
      get routes.document_path(document)
      expect(response.body).not_to include("Approve")
      post routes.approve_document_path(document)
      expect(response).to have_http_status(:forbidden)
      post routes.void_document_path(document)
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "shows only the organization's own" do
    other = create(:organization, currency: "AUD")
    stranger = TudlaAccounting::Contact.create!(organization: other, name: "Stranger")
    TudlaAccounting::AccountsCreator.call([ { code: "4000", name: "Theirs", category: "income" } ], other)
    theirs = TudlaAccounting::Document.create!(organization: other, kind: "sales_invoice", contact: stranger, issued_on: Date.current,
                                               lines_attributes: [ { description: "x", unit_price_cents: 1, account: TudlaAccounting::Account.find_by!(organization: other, code: "4000") } ])
    get routes.document_path(theirs)
    expect(response).to have_http_status(:not_found)
    post routes.documents_path, params: { document: invoice_params(contact_id: stranger.id) }
    expect(response).to have_http_status(:not_found)
  end
end
