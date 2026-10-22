require "rails_helper"
require_relative "../../support/configuration"
require_relative "../../support/test_jobs"

RSpec.describe TudlaAccounting::RecurringInvoice do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer", email: "ap@northwind.test", payment_terms_days: 14) }
  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200")) }
  let(:eng) { TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department").dimension_values.create!(code: "ENG", name: "Engineering") }

  before do
    TudlaAccounting.configuration.document_mail_from = "accounts@acme.test"
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }, { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def retainer(contact: northwind, lines: [ { description: "Retainer", quantity: 2, unit_price_cents: 500_00 } ], **attrs)
    TudlaAccounting::RecurringInvoice.new(organization: organization, name: "Retainer", contact: contact, frequency: "monthly", day_of_month: 1, starts_on: Date.new(2026, 1, 1), **attrs).tap do |template|
      lines.each { |line| template.lines.build(account: account("4000"), tax_code: gst, **line) }
    end
  end

  describe "the template" do
    it "makes the invoice for a date: its lines, dimensions, notes, and due on the customer's terms or its own days" do
      template = retainer(reference: "PO 7", notes: "Thanks!", lines: [ { description: "Retainer", quantity: 2, unit_price_cents: 500_00, dimension_value_ids: [ eng.id ] } ])
      template.save!
      expect(template.total).to eq(Money.new(1_100_00, "AUD"))
      invoice = template.build_invoice(on: Date.new(2026, 2, 1))
      expect(invoice).to have_attributes(kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 2, 1), due_on: Date.new(2026, 2, 15), reference: "PO 7",
                                         notes: "Thanks!", recurring_invoice: template, idempotency_key: "recurring_invoice:#{template.id}:2026-02-01")
      expect(invoice.lines.map { |line| [ line.description, line.quantity, line.unit_price_cents, line.dimension_value_ids ] }).to eq([ [ "Retainer", 2, 500_00, [ eng.id ] ] ])

      template.update!(due_days: 0, tax_inclusive: true)
      expect(template.build_invoice(on: Date.new(2026, 2, 1)).due_on).to eq(Date.new(2026, 2, 1))
      expect(template.total).to eq(Money.new(1_000_00, "AUD"))
    end

    it "must make an invoice that could be saved" do
      expect(retainer(lines: []).tap(&:valid?).errors.full_messages).to eq([ "Add at least one line" ])

      supplier = TudlaAccounting::Contact.create!(organization: organization, name: "Cloudware", kind: "supplier")
      expect(retainer(contact: supplier).tap(&:valid?).errors.full_messages).to eq([ "Contact must be a customer" ])
      expect(retainer(lines: [ { description: "Stock", account: account("1100") } ]).tap(&:valid?).errors.full_messages)
        .to eq([ "Lines account can't be the receivables or payables account; the document posts its total there" ])
      expect(retainer(contact: nil)).not_to be_valid
      expect(retainer(issue: "post", due_days: -1).tap(&:valid?).errors.attribute_names).to include(:issue, :due_days)
    end

    it "can still be changed once its customer is inactive, but not given an inactive one" do
      template = retainer.tap(&:save!)
      northwind.update!(active: false)
      expect(template.update(active: false)).to be(true)
      other = retainer(name: "Other")
      expect(other.tap(&:valid?).errors.full_messages).to eq([ "Contact is inactive" ])
    end

    it "is audited, and leaves its invoices when deleted" do
      template = retainer.tap(&:save!)
      template.update!(name: "Monthly retainer", next_on: Date.new(2026, 5, 1))
      template.update_columns(last_problem: "x")
      invoice = template.build_invoice(on: Date.new(2026, 1, 1)).tap(&:save!)
      template.destroy!
      expect(invoice.reload.recurring_invoice_id).to be_nil
      expect(TudlaAccounting::AuditEvent.where(subject_type: described_class.name).order(:id).map { |event| [ event.action, event.details.dig("changes")&.keys ] })
        .to eq([ [ "recurring_invoice.created", nil ], [ "recurring_invoice.updated", [ "name" ] ], [ "recurring_invoice.deleted", nil ] ])
    end
  end

  describe TudlaAccounting::RecurringInvoiceRunner do
    include_context "with the test job adapter"

    def run(as_of) = described_class.call(organization: organization, as_of: as_of)

    it "makes drafts, catching up, never the same date twice, and picks up after a change of schedule" do
      template = retainer.tap(&:save!)
      result = run(Date.new(2026, 3, 15))
      expect(result.created.map(&:issued_on)).to eq([ Date.new(2026, 1, 1), Date.new(2026, 2, 1), Date.new(2026, 3, 1) ])
      expect(result.created).to all(be_draft)
      expect(result.approved).to be_empty
      expect(template.reload).to have_attributes(next_on: Date.new(2026, 4, 1), occurrences_count: 3, last_problem: nil)
      expect(run(Date.new(2026, 3, 31)).created).to be_empty

      template.update!(day_of_month: 15)
      expect(template.next_on).to eq(Date.new(2026, 3, 15))
      expect(run(Date.new(2026, 3, 31)).created.map(&:issued_on)).to eq([ Date.new(2026, 3, 15) ])
      expect(template.invoices.count).to eq(4)
      expect(TudlaAccounting::AuditEvent.where(action: "recurring_invoice.generated").count).to eq(4)
    end

    it "approves each, or approves and emails it" do
      approving = retainer(issue: "approve").tap(&:save!)
      emailing = retainer(name: "Support", issue: "email", day_of_month: 2, starts_on: Date.new(2026, 1, 2)).tap(&:save!)
      result = run(Date.new(2026, 1, 2))
      expect(result.created.map(&:recurring_invoice)).to eq([ approving, emailing ])
      expect(result.approved.map(&:number_label)).to eq(%w[INV-0001 INV-0002])
      expect(result.emailed).to eq([ emailing.invoices.sole ])
      expect(TudlaAccounting::Delivery.sole).to have_attributes(subject: emailing.invoices.sole, kind: "document", to: "ap@northwind.test")
      expect(emailing.invoices.sole.entry.details.map(&:amount_cents)).to contain_exactly(1_100_00, 1_000_00, 100_00)
    end

    it "keeps what went wrong: an invoice left a draft, one not emailed, one that couldn't be made" do
      year.children.order(:from_date).first.close!
      closed = retainer(issue: "approve").tap(&:save!)
      globex = TudlaAccounting::Contact.create!(organization: organization, name: "Globex", kind: "customer")
      no_email = retainer(name: "Globex support", contact: globex, issue: "email", starts_on: Date.new(2026, 2, 1)).tap(&:save!)
      stuck = retainer(name: "Stuck", starts_on: Date.new(2026, 2, 1)).tap(&:save!)
      account("4000").update!(active: false)
      stuck.lines.first.update_columns(account_id: account("6000").id)
      account("4000").update!(active: true)
      account("6000").update!(active: false)

      result = run(Date.new(2026, 2, 1))
      expect(result.problems).to contain_exactly(
        start_with("Retainer: 1 Jan 2026: left as a draft: "), "Globex support: 1 Feb 2026: Invoice INV-0002 wasn't emailed: Globex has no email address",
        "Stuck: 1 Feb 2026: Lines account is inactive"
      )
      expect(closed.reload.last_problem).to be_nil # February's went through
      expect(closed.invoices.order(:issued_on).map(&:status)).to eq(%w[draft approved])
      expect(no_email.reload).to have_attributes(occurrences_count: 1, last_problem: start_with("1 Feb 2026: Invoice INV-0002 wasn't emailed"))
      expect(stuck.reload).to have_attributes(occurrences_count: 0, next_on: Date.new(2026, 2, 1), last_problem: "1 Feb 2026: Lines account is inactive")
      expect(TudlaAccounting::Delivery.count).to eq(0)
    end

    it "skips inactive and finished templates, and runs from the job as the recurring invoices actor" do
      retainer(active: false).save!
      retainer(name: "Once", occurrences_limit: 1).save!
      expect(run(Date.new(2026, 1, 1)).created.size).to eq(1)
      expect(run(Date.new(2026, 6, 1)).created).to be_empty

      retainer(name: "Weekly", frequency: "weekly", starts_on: Date.new(2026, 7, 6)).save!
      allow(Rails.logger).to receive(:warn)
      account("4000").update!(active: false)
      TudlaAccounting::RecurringInvoicesJob.perform_now("2026-07-06")
      expect(Rails.logger).to have_received(:warn).with("Recurring invoices: Weekly: 6 Jul 2026: Lines account is inactive")
      account("4000").update!(active: true)
      TudlaAccounting::RecurringInvoicesJob.perform_now("2026-07-06")
      expect(TudlaAccounting::AuditEvent.where(action: "recurring_invoice.generated").last.actor_label).to eq("Recurring invoices")
    end
  end
end
