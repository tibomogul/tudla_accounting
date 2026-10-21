require "rails_helper"
require_relative "../../support/configuration"
require_relative "../../support/test_jobs"

RSpec.describe TudlaAccounting::Delivery do
  include_context "with isolated TudlaAccounting configuration"
  include_context "with the test job adapter"

  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", email: "ap@northwind.test") }
  let(:invoice) do
    TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 3, 1), due_on: Date.new(2026, 3, 31),
                                      lines_attributes: [ { description: "Consulting", unit_price_cents: 100_00, account: account("4000") } ]).approve!
  end

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "4000", name: "Sales", category: "income" }
    ], organization)
    ActionMailer::Base.deliveries.clear
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def request!(**attrs) = described_class.request!(**{ subject: invoice, kind: "document", to: "ap@northwind.test", subject_line: "Invoice INV-0001", message: "Please pay." }.merge(attrs))

  it "records an email, tidying its addresses, and queues it as whoever asked" do
    delivery = TudlaAccounting::Current.set(actor: "Sam") { request!(to: " ap@northwind.test; boss@northwind.test ,ap@northwind.test", cc: "  ", subject_line: "  Invoice   INV-0001 ") }
    expect(delivery).to have_attributes(organization: organization, status: "queued", to: "ap@northwind.test, boss@northwind.test", cc: nil,
                                        subject_line: "Invoice INV-0001", requested_by: "Sam", recipients: %w[ap@northwind.test boss@northwind.test], cc_recipients: [])
    expect(TudlaAccounting::DeliveryJob).to have_been_enqueued.with(delivery)

    bad = described_class.new(subject: invoice, organization: organization, kind: "fax", to: "nope, ap@northwind.test", cc: "wrong@", subject_line: "", message: "")
    expect(bad).not_to be_valid
    expect(bad.errors.full_messages).to contain_exactly("Kind is not included in the list", "Subject line can't be blank", "Message can't be blank",
                                                        "nope and wrong@ aren't email addresses")
    expect(described_class.new(to: "nope").tap(&:valid?).errors[:base]).to eq([ "nope isn't an email address" ])
  end

  it "sends the invoice with its PDF, from and replying to the settings, and keeps it sent" do
    TudlaAccounting.configuration.document_mail_from = ->(org) { "#{org.name} <accounts@acme.test>" }
    TudlaAccounting.configuration.document_mail_reply_to = "billing@acme.test"
    delivery = request!(cc: "boss@northwind.test", message: "Please pay.\n\nThanks")
    perform_enqueued_jobs

    mail = ActionMailer::Base.deliveries.sole
    expect(mail).to have_attributes(to: [ "ap@northwind.test" ], cc: [ "boss@northwind.test" ], from: [ "accounts@acme.test" ], reply_to: [ "billing@acme.test" ], subject: "Invoice INV-0001")
    expect(mail[:from].value).to eq("Acme <accounts@acme.test>")
    expect(mail.text_part.decoded).to include("Please pay.\n\nThanks")
    expect(mail.html_part.decoded).to include("<p>Please pay.</p>", "<p>Thanks</p>")
    attachment = mail.attachments.sole
    expect(attachment).to have_attributes(filename: "INV-0001.pdf", mime_type: "application/pdf")
    expect(PDF::Reader.new(StringIO.new(attachment.decoded)).pages.first.text).to include("INV-0001")

    expect(delivery.reload).to have_attributes(status: "sent", sent?: true, error: nil)
    expect(delivery.sent_at).to be_present
    event = TudlaAccounting::AuditEvent.find_by!(action: "email.sent")
    expect(event).to have_attributes(subject: invoice, actor_label: nil, details: { "delivery_id" => delivery.id, "kind" => "document", "to" => "ap@northwind.test" })

    delivery.deliver! # only once
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end

  it "sends without a PDF when the engine can't make them, through the host's default From" do
    defaults = ActionMailer::Base.default_params
    ActionMailer::Base.default(from: "default@acme.test")
    allow(TudlaAccounting).to receive(:pdf?).and_return(false)
    request!
    perform_enqueued_jobs
    expect(ActionMailer::Base.deliveries.sole).to have_attributes(from: [ "default@acme.test" ], attachments: [])
  ensure
    ActionMailer::Base.default_params = defaults
  end

  it "keeps a failure with its error, on the audit trail, to be sent again" do
    allow(TudlaAccounting::PdfMaker).to receive(:document).and_raise(TudlaAccounting::PdfMaker::Error, "The PDF couldn't be made (Chrome went away)")
    delivery = TudlaAccounting::Current.set(actor: "Sam") { request! }
    perform_enqueued_jobs
    expect(delivery.reload).to have_attributes(status: "failed", failed?: true, error: "The PDF couldn't be made (Chrome went away)")
    expect(ActionMailer::Base.deliveries).to be_empty
    event = TudlaAccounting::AuditEvent.find_by!(action: "email.failed")
    expect(event).to have_attributes(actor_label: "Sam", details: include("error" => "The PDF couldn't be made (Chrome went away)"))

    again = delivery.resend!
    expect(again).to have_attributes(status: "queued", to: delivery.to, subject_line: delivery.subject_line, message: delivery.message, kind: "document")
    expect(again).not_to eq(delivery)
  end

  it "sends through the host's own mailer when the setting names one" do
    host_mailer = Class.new(ActionMailer::Base) do
      def delivery(delivery, pdf:, filename:)
        mail(to: delivery.recipients, from: "host@acme.test", subject: "Host: #{delivery.subject_line} #{filename}", body: "pdf #{pdf ? pdf.bytesize.positive? : 'none'}")
      end
    end
    stub_const("HostDocumentMailer", host_mailer)
    TudlaAccounting.configuration.document_mailer = "HostDocumentMailer"
    request!
    perform_enqueued_jobs
    expect(ActionMailer::Base.deliveries.sole).to have_attributes(subject: "Host: Invoice INV-0001 INV-0001.pdf", from: [ "host@acme.test" ])
  end

  it "attaches a payment as its receipt or payment notice" do
    payment = TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 3, 20),
                                               amount_cents: 100_00, applications: [ { document: invoice, amount_cents: 100_00 } ])
    pdf, filename = described_class.new(subject: payment, kind: "receipt").attachment
    expect(filename).to eq("receipt-2026-03-20.pdf")
    expect(PDF::Reader.new(StringIO.new(pdf)).pages.first.text).to include("Receipt")
  end
end
