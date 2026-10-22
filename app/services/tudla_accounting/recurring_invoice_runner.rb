# frozen_string_literal: true

module TudlaAccounting
  # Makes the invoices recurring invoices have due by a date (today by default, in the
  # configured time zone), catching up any missed: each a draft, approved, or approved and
  # emailed, as its template says. RecurringInvoicesJob runs it for every organization; the
  # host app schedules that job (daily, say).
  #
  #   RecurringInvoiceRunner.call(organization: org, as_of: Date.new(2026, 11, 1))
  #   # => #<Result created=[invoice, ...] approved=[...] emailed=[...] problems=["Retainer: 1 Nov 2026: ..."]>
  #
  # Each template is locked while it runs and moves on in the same transaction as the
  # invoice is made, and each invoice's idempotency key names the template and date, so
  # runs that overlap make each invoice once. A template whose invoice can't be made (the
  # customer made inactive since, say) stops there and keeps the reason in last_problem,
  # to be tried again next run. An invoice that can't be approved (its month closed) is
  # left as a draft, and one whose customer has no email address isn't emailed; the reason
  # is kept either way.
  class RecurringInvoiceRunner
    Result = Struct.new(:created, :approved, :emailed, :problems, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(organization: nil, as_of: nil)
      @organization = organization
      @as_of = as_of || ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today
      @result = Result.new(created: [], approved: [], emailed: [], problems: [])
    end

    def call
      due = RecurringInvoice.active.where(next_on: ..@as_of)
      due = due.where(organization: @organization) if @organization
      due.order(:next_on, :id).each { |template| run(template) }
      @result
    end

    private

    def run(template)
      template.with_lock do
        while template.due?(@as_of)
          on = template.next_on
          invoice = make(template, on)
          break unless invoice

          template.advance!(on, problem: (issue(template, invoice, on) if template.approves?))
        end
      end
    end

    # The invoice for a date, saved as a draft; nil (with the problem kept) when it can't be.
    def make(template, on)
      invoice = Document.transaction(requires_new: true) { template.build_invoice(on: on).tap(&:save!) }
      @result.created << invoice
      AuditEvent.record!("recurring_invoice.generated", organization: template.organization, subject: template, details: { document_id: invoice.id, on: on.iso8601 })
      invoice
    rescue ActiveRecord::RecordInvalid => e
      template.update_columns(last_problem: problem(template, on, e.record.errors.full_messages.to_sentence))
      nil
    end

    # Approves the invoice, and emails it when the template says so; what went wrong, if
    # anything.
    def issue(template, invoice, on)
      invoice.approve!
      @result.approved << invoice
      return unless template.emails?

      draft = EmailDraft.for_document(invoice)
      return problem(template, on, "#{invoice.title} wasn't emailed: #{invoice.contact.name} has no email address") if draft[:to].blank?

      Delivery.request!(subject: invoice, **draft)
      @result.emailed << invoice
      nil
    rescue ArgumentError => e
      problem(template, on, "left as a draft: #{e.message.downcase_first}")
    end

    def problem(template, on, message)
      text = "#{on.strftime('%-d %b %Y')}: #{message}"
      @result.problems << "#{template.name}: #{text}"
      text
    end
  end
end
