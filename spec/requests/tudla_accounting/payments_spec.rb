require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Payments", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post] }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both") }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1010", name: "Petty cash", category: "asset" },
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "4000", name: "Sales", category: "income" },
      { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def document(kind = "sales_invoice", cents = 100_00, issued_on: Date.new(2026, 4, 1))
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: northwind, issued_on: issued_on, due_on: issued_on + 30,
                                      lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account(kind == "bill" ? "6000" : "4000") } ]).approve!
  end

  it "records a payment from an invoice's page, applied to it, and lists it" do
    TudlaAccounting.configuration.cash_account_codes = %w[1010]
    invoice = document
    get routes.document_path(invoice)
    expect(response.body).to include("Record payment")

    get routes.new_payment_path(document_id: invoice.id)
    expect(css_select("h1").first.text).to eq("Record a payment received")
    expect(css_select("input[name='payment[amount]']").first["value"]).to eq("100.00")
    expect(css_select("input[name='payment[applications][#{invoice.id}]']").first["value"]).to eq("100.00")
    expect(css_select("select[name='payment[account_id]'] option[selected]").map(&:text)).to eq([ "1010 - Petty cash" ])
    expect(css_select("select[name='payment[account_id]'] option").map(&:text)).not_to include("1100 - Receivables", "4000 - Sales")

    post routes.payments_path, params: { payment: { kind: "received", contact_id: northwind.id, account_id: account("1000").id, paid_on: "2026-04-14", amount: "120",
                                                    reference: "EFT 1", applications: { invoice.id.to_s => "100.00" } } }
    payment = TudlaAccounting::Payment.last
    expect(response).to redirect_to(routes.payment_path(payment))
    expect(flash[:notice]).to eq("Payment from Northwind of $120.00 recorded.")
    expect(invoice.reload.payment_status).to eq("paid")

    get routes.payment_path(payment)
    expect(css_select("[data-details]").first.text.squish).to include("1000 - Bank", "EFT 1", "$120.00", "Not applied yet$20.00")
    expect(response.body).to include("Invoice INV-0001", "Apply the rest", "Credit to apply")
    get routes.new_payment_path(document_id: invoice.id) # paid now, but it can still be chosen from the page...
    expect(css_select("tr[data-open-document]")).to be_empty # ...though there's nothing left to apply
    expect(css_select("select[name='payment[account_id]'] option[selected]").map(&:text)).to eq([ "1000 - Bank" ]) # the last one used

    get routes.received_payments_path
    expect(css_select("tr[data-payment-row]").map { |row| row.text.squish }).to eq([ "14 Apr 2026 Northwind EFT 1 1000 - Bank 120.00 20.00 Credit to apply" ])
    get routes.received_payments_path(q: "nobody")
    expect(response.body).to include("Nothing matches.")
    get routes.received_payments_path(format: :csv)
    expect(response.body.lines.map(&:chomp)).to eq([ "Date,Contact,Reference,Account,Amount,Unapplied,Status", "2026-04-14,Northwind,EFT 1,1000,120.00,20.00,posted" ])
    get routes.paid_payments_path
    expect(response.body).to include("No payments yet.")
    get routes.entry_path(payment.entry)
    expect(response.body).to include("Posted for the", "payment from Northwind")
    get routes.sales_documents_path
    expect(response.body).to include("Payments received")
  end

  it "picks the contact first, then lists what they owe, and says what's wrong" do
    first = document
    second = document("sales_invoice", 50_00, issued_on: Date.new(2026, 3, 1))
    document("bill")
    get routes.new_payment_path(kind: "received")
    expect(response.body).not_to include("Apply it to")
    get routes.new_payment_path(kind: "received", contact_id: northwind.id)
    expect(css_select("tr[data-open-document] td:first-child").map(&:text)).to eq(%w[INV-0002 INV-0001])

    params = { kind: "received", contact_id: northwind.id, account_id: account("1000").id, paid_on: "2026-04-14", amount: "100",
               applications: { first.id.to_s => "80", second.id.to_s => "50" } }
    post routes.payments_path, params: { payment: params }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("The payment is $100.00 but $130.00 is applied")
    expect(css_select("input[name='payment[applications][#{first.id}]']").first["value"]).to eq("80.00")
    post routes.payments_path, params: { payment: params.merge(amount: "lots") }
    expect(response.body).to include("lots isn&#39;t an amount (the payment)")
    post routes.payments_path, params: { payment: params.merge(amount: "130") }
    expect([ first.reload.amount_due.cents, second.reload.amount_due.cents ]).to eq([ 20_00, 0 ])
    expect(TudlaAccounting::AuditEvent.find_by!(action: "payment.recorded").details["documents"]).to contain_exactly("INV-0001", "INV-0002")

    get routes.new_payment_path(kind: "paid", contact_id: northwind.id)
    expect(css_select("h1").first.text).to eq("Record a payment made")
    expect(css_select("tr[data-open-document] td:first-child").map(&:text)).to eq(%w[BILL-0001])
    get routes.new_payment_path(kind: "received", contact_id: TudlaAccounting::Contact.create!(organization: organization, name: "Globex").id)
    expect(response.body).to include("Nothing is owed by Globex")

    get routes.activity_path(kind: "payment")
    expect(response.body).to include("Recorded", "for INV-0001 and INV-0002")
  end

  it "voids a payment, putting what it paid back as owed" do
    invoice = document
    payment = TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 4, 10),
                                               amount_cents: 100_00, applications: [ { document: invoice, amount_cents: 100_00 } ])
    post routes.void_payment_path(payment), params: { on: "nope", reason: "x" }
    expect(flash[:alert]).to start_with("It wasn't voided: ")
    post routes.void_payment_path(payment), params: { on: "2026-04-15", reason: "Bounced" }
    expect(flash[:notice]).to eq("Payment voided: its entry is reversed on 15 Apr 2026.")
    expect(invoice.reload.amount_due.cents).to eq(100_00)
    get routes.payment_path(payment)
    expect(response.body).to include("Voided 15 Apr 2026", "Bounced", "(taken off)")
    get routes.received_payments_path(status: "void")
    expect(css_select("tr[data-payment-row]").size).to eq(1)
    get routes.activity_path(kind: "payment")
    expect(response.body).to include("Voided", "Bounced")
  end

  it "records a bank statement line as a payment of an open invoice or bill, and matches it" do
    invoice = document
    bill = document("bill", 40_00)
    money_in = TudlaAccounting::BankStatementLine.create!(organization: organization, account: account("1000"), occurred_on: Date.new(2026, 4, 12), description: "NORTHWIND PTY",
                                                          reference: "REF 7", amount_cents: 150_00, currency: "AUD", external_id: "a")
    money_out = TudlaAccounting::BankStatementLine.create!(organization: organization, account: account("1000"), occurred_on: Date.new(2026, 4, 13), description: "NORTHWIND SUPPLIES",
                                                           amount_cents: -40_00, currency: "AUD", external_id: "b")
    get routes.banking_account_path(account("1000"))
    expect(css_select("select#document_id_#{money_in.id} option").map(&:text)).to eq([ "INV-0001 Northwind (100.00 owed)" ])
    expect(css_select("select#document_id_#{money_out.id} option").map(&:text)).to eq([ "BILL-0001 Northwind (40.00 owed)" ])

    post routes.record_payment_bank_statement_line_path(money_in), params: { document_id: bill.id }
    expect(flash[:alert]).to eq("No payment was recorded: choose an invoice.")
    post routes.record_payment_bank_statement_line_path(money_in), params: { document_id: invoice.id }
    expect(flash[:notice]).to eq("Recorded payment from Northwind for INV-0001 and matched it.")
    payment = TudlaAccounting::Payment.last
    expect(payment).to have_attributes(amount_cents: 150_00, paid_on: Date.new(2026, 4, 12), reference: "REF 7", account: account("1000"))
    expect(payment.unapplied.cents).to eq(50_00)
    expect(money_in.reload).to be_matched
    expect(invoice.reload.payment_status).to eq("paid")

    post routes.record_payment_bank_statement_line_path(money_out), params: { document_id: bill.id }
    expect(TudlaAccounting::Payment.last).to have_attributes(kind: "paid", reference: "NORTHWIND SUPPLIES")
    expect(bill.reload.payment_status).to eq("paid")
    post routes.record_payment_bank_statement_line_path(money_out), params: { document_id: bill.id }
    expect(flash[:alert]).to start_with("No payment was recorded: ")
    post routes.record_payment_bank_statement_line_path(money_out)
    expect(flash[:alert]).to start_with("No payment was recorded: param is missing")
  end

  context "without permission to post" do
    let(:permissions) { %i[read record] }

    it "shows payments but doesn't record or void them" do
      invoice = document
      get routes.document_path(invoice)
      expect(response.body).not_to include("Record payment")
      get routes.new_payment_path
      expect(response).to have_http_status(:forbidden)
      post routes.payments_path, params: { payment: { kind: "received" } }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
