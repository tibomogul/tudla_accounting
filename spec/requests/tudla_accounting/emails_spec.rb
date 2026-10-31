require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"
require_relative "../../support/test_jobs"

RSpec.describe "Emailing invoices", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include_context "with the test job adapter"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post] }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", email: "ap@northwind.test") }
  let(:invoice) { document("sales_invoice") }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    TudlaAccounting.configuration.document_mail_from = "accounts@acme.test"
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "4000", name: "Sales", category: "income" }, { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
    ActionMailer::Base.deliveries.clear
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def document(kind, approve: true)
    made = TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: northwind, issued_on: Date.new(2026, 4, 1), due_on: (Date.new(2026, 5, 1) if kind == "sales_invoice"),
                                             lines_attributes: [ { description: "Work", unit_price_cents: 100_00, account: account(kind.in?(%w[bill supplier_credit]) ? "6000" : "4000") } ])
    approve ? made.approve! : made
  end

  it "emails an invoice from its page, the email checked first, and shows how it went" do
    get routes.document_path(invoice)
    expect(css_select("a[href='#{routes.new_email_path(document_id: invoice.id)}']").map(&:text)).to eq([ "Email" ])

    get routes.new_email_path(document_id: invoice.id)
    expect(css_select("h1").first.text).to eq("Email invoice INV-0001")
    expect(css_select("input[name='delivery[to]']").first["value"]).to eq("ap@northwind.test")
    expect(css_select("input[name='delivery[subject_line]']").first["value"]).to eq("Invoice INV-0001 from Acme")
    expect(css_select("textarea[name='delivery[message]']").first.text).to include("due on 1 May 2026")
    expect(css_select("[data-attachment]").first.text.squish).to eq("Attached: INV-0001.pdf")

    post routes.emails_path(document_id: invoice.id), params: { delivery: { to: "ap@northwind.test", cc: "boss@northwind.test", subject_line: "Your invoice", message: "Thanks!" } }
    expect(response).to redirect_to(routes.document_path(invoice))
    expect(flash[:notice]).to eq("Emailing invoice INV-0001 to ap@northwind.test.")
    get routes.document_path(invoice)
    expect(css_select("[data-delivery=queued]").first.text.squish).to include("ap@northwind.test cc boss@northwind.test", "Your invoice", "Sending", "by Demo user")

    send_queued_emails
    expect(ActionMailer::Base.deliveries.sole).to have_attributes(subject: "Your invoice", from: [ "accounts@acme.test" ])
    get routes.document_path(invoice)
    expect(css_select("[data-delivery=sent]").first.text.squish).to include("Sent 15 Apr 09:00", "Send again")
    get routes.sales_documents_path
    expect(css_select("[data-emailed]").size).to eq(1)
    get routes.activity_path(kind: "email")
    expect(response.body).to include("Emailed", "Invoice INV-0001 – Northwind", "to ap@northwind.test")
  end

  it "emails a credit note too, says what's wrong with an email, and sends a failed one again" do
    credit = document("sales_credit")
    get routes.document_path(credit)
    expect(response.body).to include(routes.new_email_path(document_id: credit.id))
    get routes.new_email_path(document_id: credit.id)
    expect(css_select("input[name='delivery[subject_line]']").first["value"]).to eq("Credit note CN-0001 from Acme")

    northwind.update!(email: nil)
    get routes.new_email_path(document_id: invoice.id)
    expect(response.body).to include("Northwind has no email address yet")
    post routes.emails_path(document_id: invoice.id), params: { delivery: { to: "not an address", subject_line: "", message: "Hi" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Subject line can&#39;t be blank", "not, an, and address aren&#39;t email addresses")

    allow(TudlaAccounting::PdfMaker).to receive(:document).and_raise(TudlaAccounting::PdfMaker::Error, "The PDF couldn't be made (Chrome went away)")
    post routes.emails_path(document_id: invoice.id), params: { delivery: { to: "ap@northwind.test", subject_line: "Invoice", message: "Hi" } }
    perform_enqueued_jobs
    failed = TudlaAccounting::Delivery.sole
    get routes.document_path(invoice)
    expect(css_select("[data-delivery=failed]").first.text.squish).to include("Failed", "The PDF couldn't be made (Chrome went away)")
    get routes.sales_documents_path
    expect(css_select("[data-emailed]")).to be_empty

    allow(TudlaAccounting::PdfMaker).to receive(:document).and_call_original
    post routes.resend_email_path(failed)
    expect(response).to redirect_to(routes.document_path(invoice))
    expect(flash[:notice]).to eq("Emailing it to ap@northwind.test again.")
    perform_enqueued_jobs
    expect(TudlaAccounting::Delivery.order(:id).pluck(:status)).to eq(%w[failed sent])
    get routes.activity_path(kind: "email")
    expect(response.body).to include("Couldn&#39;t email", "Chrome went away")
  end

  it "emails only approved invoices and credit notes" do
    get routes.document_path(document("bill"))
    expect(response.body).not_to include("delivery")
    expect(response.body).not_to include(">Email<")
    [ document("bill"), document("sales_invoice", approve: false) ].each do |unsendable|
      get routes.new_email_path(document_id: unsendable.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  context "without permission to post" do
    let(:permissions) { %i[read record] }

    it "shows the emails but sends none" do
      TudlaAccounting::Delivery.request!(subject: invoice, kind: "document", to: "ap@northwind.test", subject_line: "Invoice", message: "Hi")
      get routes.document_path(invoice)
      expect(css_select("[data-emails]")).not_to be_empty
      expect(response.body).not_to include("Send again", routes.new_email_path(document_id: invoice.id))
      get routes.new_email_path(document_id: invoice.id)
      expect(response).to have_http_status(:forbidden)
      post routes.resend_email_path(TudlaAccounting::Delivery.sole)
      expect(response).to have_http_status(:forbidden)
    end
  end
end

RSpec.describe "Emailing statements, receipts and payment notices", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include_context "with the test job adapter"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", email: "ap@northwind.test") }
  let(:globex) { TudlaAccounting::Contact.create!(organization: organization, name: "Globex") }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting.configuration.document_mail_from = "accounts@acme.test"
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "4000", name: "Sales", category: "income" },
      { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
    ActionMailer::Base.deliveries.clear
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def invoice(contact, cents = 100_00)
    TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: contact, issued_on: Date.new(2026, 4, 1),
                                      lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account("4000") } ]).approve!
  end

  def pay(kind = "received", **attrs)
    TudlaAccounting::Payment.record!(organization: organization, kind: kind, contact: northwind, account: account("1000"), paid_on: Date.new(2026, 4, 10), amount_cents: 100_00, **attrs)
  end

  def statement_params(party = northwind) = { type: "receivable", party: TudlaAccounting::PartyStatement.key(party), from: "2026-04-01", thru: "2026-04-30" }

  it "emails a receipt from the payment's page, and as the payment is recorded" do
    payment = pay(applications: [ { document: invoice(northwind), amount_cents: 100_00 } ])
    get routes.payment_path(payment)
    expect(css_select("a[href='#{routes.new_email_path(payment_id: payment.id)}']").map(&:text)).to eq([ "Email receipt" ])
    get routes.new_email_path(payment_id: payment.id)
    expect(css_select("h1").first.text).to eq("Email the receipt for the payment from Northwind")
    expect(css_select("input[name='delivery[subject_line]']").first["value"]).to eq("Receipt for your payment to Acme")
    expect(css_select("[data-attachment]").first.text.squish).to eq("Attached: receipt-2026-04-10.pdf")

    post routes.emails_path(payment_id: payment.id), params: { delivery: { to: "ap@northwind.test", subject_line: "Receipt", message: "Thanks" } }
    expect(response).to redirect_to(routes.payment_path(payment))
    send_queued_emails
    expect(ActionMailer::Base.deliveries.sole.attachments.sole.filename).to eq("receipt-2026-04-10.pdf")
    get routes.payment_path(payment)
    expect(css_select("[data-delivery=sent]").size).to eq(1)
    get routes.activity_path(kind: "email")
    expect(response.body).to include("the receipt for", "Payment from Northwind of $100.00", "to ap@northwind.test")

    get routes.new_payment_path(kind: "received", contact_id: northwind.id)
    expect(response.body).to include("Email a receipt to Northwind (ap@northwind.test)")
    post routes.payments_path, params: { payment: { kind: "received", contact_id: northwind.id, account_id: account("1000").id, paid_on: "2026-04-14", amount: "20", email_it: "1" } }
    expect(flash[:notice]).to eq("Payment from Northwind of $20.00 recorded. Emailing the receipt to ap@northwind.test.")
    expect(TudlaAccounting::Delivery.order(:id).last).to have_attributes(kind: "receipt", subject: TudlaAccounting::Payment.order(:id).last)
    post routes.payments_path, params: { payment: { kind: "received", contact_id: northwind.id, account_id: account("1000").id, paid_on: "2026-04-14", amount: "5", email_it: "0" } }
    expect(flash[:notice]).to eq("Payment from Northwind of $5.00 recorded.")

    globex.update!(kind: "both")
    get routes.new_payment_path(kind: "paid", contact_id: globex.id)
    expect(response.body).to include("Email a payment notice to Globex (they have no email address yet)")
    post routes.payments_path, params: { payment: { kind: "paid", contact_id: globex.id, account_id: account("1000").id, paid_on: "2026-04-14", amount: "5", email_it: "1" } }
    expect(flash[:notice]).to end_with("It wasn't emailed: Globex has no email address.")
  end

  it "emails a payment notice, and not for a void payment" do
    payment = pay("paid")
    get routes.payment_path(payment)
    expect(response.body).to include("Email payment notice")
    post routes.emails_path(payment_id: payment.id), params: { delivery: { to: "ap@northwind.test", subject_line: "Paid", message: "Paid" } }
    send_queued_emails
    expect(ActionMailer::Base.deliveries.sole.attachments.sole.filename).to eq("payment-notice-2026-04-10.pdf")
    get routes.activity_path(kind: "email")
    expect(response.body).to include("the payment notice for")
    post routes.resend_email_path(TudlaAccounting::Delivery.sole)
    expect(response).to redirect_to(routes.payment_path(payment))

    payment.void!(on: Date.new(2026, 4, 15), reason: "Wrong")
    get routes.new_email_path(payment_id: payment.id)
    expect(response).to have_http_status(:not_found)
  end

  it "emails one statement from its page, listed there and on the contact's page" do
    invoice(northwind)
    get routes.reports_statement_path(statement_params)
    expect(css_select("a[href='#{routes.new_email_path(statement_params)}']").map(&:text)).to eq([ "Email" ])
    get routes.new_email_path(statement_params)
    expect(css_select("h1").first.text).to eq("Email Northwind's statement")
    expect(css_select("textarea[name='delivery[message]']").first.text).to include("1 Apr 2026 to 30 Apr 2026. The balance is $100.00.")
    expect(css_select("[data-attachment]").first.text.squish).to eq("Attached: statement-2026-04-30.pdf")

    post routes.emails_path(statement_params.merge(show: "open_items")), params: { delivery: { to: "ap@northwind.test", subject_line: "Statement", message: "Hi" } }
    expect(response).to redirect_to(routes.reports_statement_path(statement_params.merge(show: "open_items")))
    expect(flash[:notice]).to eq("Emailing Northwind's statement to ap@northwind.test.")
    expect(TudlaAccounting::Delivery.sole).to have_attributes(kind: "statement", subject: northwind,
                                                              details: { "type" => "receivable", "from" => "2026-04-01", "thru" => "2026-04-30", "open_items" => true })
    send_queued_emails
    attachment = ActionMailer::Base.deliveries.sole.attachments.sole
    expect(attachment.filename).to eq("statement-2026-04-30.pdf")
    expect(PDF::Reader.new(StringIO.new(attachment.decoded)).pages.first.text).to include("Open items at 30 Apr 2026", "Northwind")

    get routes.reports_statement_path(statement_params)
    expect(css_select("[data-delivery=sent]").size).to eq(1)
    get routes.contact_path(northwind)
    expect(css_select("[data-emails] [data-delivery=sent]").size).to eq(1)
    get routes.activity_path(kind: "email")
    expect(css_select("table").first.text.squish).to include("Emailed Northwind's statement to ap@northwind.test")
    post routes.resend_email_path(TudlaAccounting::Delivery.sole)
    expect(response).to redirect_to(routes.reports_statement_path(statement_params.merge(show: "open_items")))

    [ statement_params.merge(type: "nonsense"), statement_params.merge(from: "1 April"), statement_params.merge(party: "Contact_0") ].each do |bad|
      get routes.new_email_path(bad)
      expect(response).to have_http_status(:not_found), bad.inspect
    end
  end

  it "emails every statement with something to send, naming those it can't" do
    invoice(northwind)
    invoice(globex, 50_00)
    params = statement_params.except(:party)
    get routes.reports_statements_path(params)
    expect(response.body).to include("Email them all")
    post routes.statements_emails_path(params)
    expect(response).to redirect_to(routes.reports_statements_path(params))
    expect(flash[:notice]).to eq("Emailing 1 statement.")
    expect(flash[:alert]).to eq("Not emailed, as they have no email address: Globex.")
    expect(TudlaAccounting::Delivery.sole).to have_attributes(subject: northwind, to: "ap@northwind.test", kind: "statement")

    post routes.statements_emails_path(params.merge(type: "payable"))
    expect(flash[:notice]).to eq("No statements to email.")
    expect(flash[:alert]).to be_nil
  end
end
