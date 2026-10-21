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
    expect(flash[:notice]).to eq("Emailing Invoice INV-0001 to ap@northwind.test.")
    get routes.document_path(invoice)
    expect(css_select("[data-delivery=queued]").first.text.squish).to include("ap@northwind.test cc boss@northwind.test", "Your invoice", "Sending", "by Demo user")

    perform_enqueued_jobs
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
