# frozen_string_literal: true

module TudlaAccounting
  # Reminds customers of overdue invoices, on the reminder_days setting's days after the
  # due date: one email per invoice for each of those days it has reached, as the
  # "reminder" template says, with the invoice attached.
  #
  #   ReminderRunner.due(organization: org)  # => [#<Reminder invoice=... days=14 days_overdue=16>, ...]
  #   ReminderRunner.call(organization: org) # => #<Result sent=[...] no_address=[...]>
  #
  # Only an invoice's latest reminder day is sent (no catching up on the ones before),
  # never one already sent or on its way (or a later one), and never for an invoice that is
  # paid, void, or without a due date. A reminder that failed is due again. A customer
  # without an email address is left out, and named in the result. SendRemindersJob runs
  # it for every organization; the host app schedules that job (daily, say). As of today
  # (in the configured time zone) unless given a date.
  class ReminderRunner
    Reminder = Struct.new(:invoice, :days, :days_overdue, keyword_init: true) do
      # "2nd reminder", by its place among the reminder days.
      def label
        place = TudlaAccounting.configuration.reminder_days_for(invoice.organization).index(days)
        place ? "#{(place + 1).ordinalize} reminder" : "Reminder"
      end
    end
    Result = Struct.new(:sent, :no_address, keyword_init: true)

    def self.due(...) = new(...).due
    def self.call(...) = new(...).call

    def initialize(organization: nil, as_of: nil)
      @organization = organization
      @as_of = as_of
    end

    # The reminders due, oldest due date first.
    def due
      first = @organization ? days_for(@organization).first : 1
      return [] unless first

      invoices = Document.approved.where(kind: "sales_invoice", due_on: ..(latest - first)).with_open_cents.includes(:contact, :organization).order(:due_on, :id)
      invoices = invoices.where(organization: @organization) if @organization
      invoices = invoices.to_a.select { |invoice| invoice.amount_due.positive? }
      reached = sent_days(invoices)
      invoices.filter_map do |invoice|
        overdue = (today(invoice.organization) - invoice.due_on).to_i
        stage = days_for(invoice.organization).select { |day| day <= overdue }.max
        Reminder.new(invoice: invoice, days: stage, days_overdue: overdue) unless stage.nil? || (reached[invoice.id] && reached[invoice.id] >= stage)
      end
    end

    # Sends the reminders due, each once even when runs overlap (the invoice is locked
    # while its reminder is queued).
    def call
      result = Result.new(sent: [], no_address: [])
      due.each do |reminder|
        draft = EmailDraft.for_reminder(reminder.invoice, days: reminder.days)
        next result.no_address << reminder if draft[:to].blank?

        Document.transaction do
          reminder.invoice.lock!
          next if sent_days([ reminder.invoice ]).fetch(reminder.invoice.id, 0) >= reminder.days

          Delivery.request!(subject: reminder.invoice, **draft)
          result.sent << reminder
        end
      end
      result
    end

    private

    # The day it is in an organization's time zone (as_of if given), and the latest day it
    # is in any of those run.
    def today(organization) = @as_of || TudlaAccounting.zone(organization).today
    def latest = @as_of || (@organization ? today(@organization) : Time.current.utc.to_date + 1)

    # Each organization's reminder_days, read once.
    def days_for(organization)
      (@days ||= {})[[ organization.class.name, organization.id ]] ||= TudlaAccounting.configuration.reminder_days_for(organization)
    end

    # { invoice id => the latest reminder day sent or on its way }.
    def sent_days(invoices)
      Delivery.where(kind: "reminder", subject_type: Document.name, subject_id: invoices.map(&:id), status: %w[queued sent]).where.not(stage: nil)
              .group(:subject_id).maximum(:stage)
    end
  end
end
