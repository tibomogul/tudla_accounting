require "rails_helper"
require_relative "../../support/configuration"
require_relative "../../support/test_jobs"

RSpec.describe TudlaAccounting::ReminderRunner, type: :service do
  include_context "with isolated TudlaAccounting configuration"
  include_context "with the test job adapter"

  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", email: "ap@northwind.test") }
  let(:globex) { TudlaAccounting::Contact.create!(organization: organization, name: "Globex") }

  before do
    TudlaAccounting.configuration.reminder_days = [ 30, "7", 14, 7 ]
    TudlaAccounting.configuration.document_mail_from = "accounts@acme.test"
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "4000", name: "Sales", category: "income" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def invoice(contact, due_on, kind: "sales_invoice", cents: 100_00)
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: contact, issued_on: Date.new(2026, 3, 1), due_on: due_on,
                                      lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account("4000") } ]).approve!
  end

  def due(as_of) = described_class.due(organization: organization, as_of: as_of).map { |reminder| [ reminder.invoice.number_label, reminder.days, reminder.days_overdue, reminder.label ] }

  it "keeps the reminder days whole, positive and in order" do
    expect(TudlaAccounting.configuration.reminder_days).to eq([ 7, 14, 30 ])
    [ [ 0 ], [ "soon" ], [ -7 ] ].each do |days|
      expect { TudlaAccounting.configuration.reminder_days = days }.to raise_error(ArgumentError, "reminder_days must be whole numbers of days, more than zero")
    end
  end

  it "finds each overdue invoice's latest reminder day reached, and nothing paid, void, undated, or a credit note" do
    invoice(northwind, Date.new(2026, 4, 1)) # INV-0001
    invoice(northwind, Date.new(2026, 4, 10)) # INV-0002
    paid = invoice(northwind, Date.new(2026, 3, 1))
    TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 3, 20),
                                     amount_cents: 100_00, applications: [ { document: paid, amount_cents: 100_00 } ])
    invoice(northwind, Date.new(2026, 3, 2)).void!(on: Date.new(2026, 3, 31), reason: "Wrong")
    invoice(northwind, nil)
    invoice(northwind, Date.new(2026, 3, 3), kind: "sales_credit")

    expect(due(Date.new(2026, 4, 7))).to eq([])
    expect(due(Date.new(2026, 4, 8))).to eq([ [ "INV-0001", 7, 7, "1st reminder" ] ])
    expect(due(Date.new(2026, 4, 20))).to eq([ [ "INV-0001", 14, 19, "2nd reminder" ], [ "INV-0002", 7, 10, "1st reminder" ] ])
    expect(due(Date.new(2026, 6, 1)).map(&:second)).to eq([ 30, 30 ])
    TudlaAccounting.configuration.reminder_days = []
    expect(due(Date.new(2026, 6, 1))).to eq([])
  end

  it "sends each reminder once, with the invoice, skipping customers without an email address" do
    first = invoice(northwind, Date.new(2026, 4, 1))
    invoice(globex, Date.new(2026, 4, 1))
    result = TudlaAccounting::Current.set(actor: "Reminders") { described_class.call(organization: organization, as_of: Date.new(2026, 4, 9)) }
    expect(result.sent.map { |reminder| reminder.invoice.number_label }).to eq([ "INV-0001" ])
    expect(result.no_address.map { |reminder| reminder.invoice.contact.name }).to eq([ "Globex" ])
    delivery = TudlaAccounting::Delivery.sole
    expect(delivery).to have_attributes(subject: first, kind: "reminder", stage: 7, to: "ap@northwind.test", subject_line: "Reminder: invoice INV-0001 is overdue", requested_by: "Reminders")
    expect(delivery.message).to include("Invoice INV-0001, due on 1 Apr 2026, still has $100.00 owing.")

    expect(described_class.call(organization: organization, as_of: Date.new(2026, 4, 10)).sent).to eq([]) # queued: not again
    send_queued_emails
    expect(ActionMailer::Base.deliveries.last.attachments.sole.filename).to eq("INV-0001.pdf")
    expect(described_class.call(organization: organization, as_of: Date.new(2026, 4, 10)).sent).to eq([]) # sent: not again
    expect(described_class.call(organization: organization, as_of: Date.new(2026, 4, 15)).sent.map(&:days)).to eq([ 14 ])

    TudlaAccounting::Delivery.where(stage: 14).update_all(status: "failed")
    expect(described_class.call(organization: organization, as_of: Date.new(2026, 4, 16)).sent.map(&:days)).to eq([ 14 ]) # failed: due again
  end

  it "doesn't send one that another run queued meanwhile" do
    invoice(northwind, Date.new(2026, 4, 1))
    runner = described_class.new(organization: organization, as_of: Date.new(2026, 4, 9))
    reminders = runner.due
    TudlaAccounting::Delivery.request!(subject: reminders.first.invoice, kind: "reminder", stage: 7, to: "ap@northwind.test", subject_line: "Reminder", message: "Hi")
    allow(runner).to receive(:due).and_return(reminders)
    expect(runner.call.sent).to eq([])
    expect(TudlaAccounting::Delivery.count).to eq(1)
  end

  it "runs for every organization from the job, as Reminders, logging those it can't remind" do
    other = create(:organization, name: "Other", currency: "AUD")
    TudlaAccounting::PeriodCreator.call(other, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "4000", name: "Sales", category: "income" } ], other)
    theirs = TudlaAccounting::Contact.create!(organization: other, name: "Theirs", email: "ap@theirs.test")
    TudlaAccounting::Document.create!(organization: other, kind: "sales_invoice", contact: theirs, issued_on: Date.new(2026, 3, 1), due_on: Date.new(2026, 4, 1),
                                      lines_attributes: [ { description: "Work", unit_price_cents: 5_00, account: TudlaAccounting::Account.find_by!(organization: other, code: "4000") } ]).approve!
    invoice(northwind, Date.new(2026, 4, 1))
    invoice(globex, Date.new(2026, 4, 1))
    allow(Rails.logger).to receive(:warn)

    TudlaAccounting::SendRemindersJob.perform_now("2026-04-09")
    expect(TudlaAccounting::Delivery.pluck(:to, :requested_by)).to contain_exactly([ "ap@northwind.test", "Reminders" ], [ "ap@theirs.test", "Reminders" ])
    expect(Rails.logger).to have_received(:warn).with("Reminders: Invoice INV-0002 – Globex wasn't reminded: Globex has no email address")
  end

  it "labels a reminder by its day's place, or plainly for one sent by hand" do
    expect(described_class::Reminder.new(days: 14).label).to eq("2nd reminder")
    expect(described_class::Reminder.new(days: nil).label).to eq("Reminder")
  end
end
