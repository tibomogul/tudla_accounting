# frozen_string_literal: true

module TudlaAccounting
  # Sends every organization's overdue-invoice reminders that are due (ReminderRunner),
  # as "Reminders" on the audit trail. The host app schedules it, e.g. daily with Solid
  # Queue's config/recurring.yml:
  #
  #   reminders:
  #     class: TudlaAccounting::SendRemindersJob
  #     schedule: every day at 9am
  #
  # Customers without an email address are logged.
  class SendRemindersJob < ApplicationJob
    queue_as :default

    def perform(as_of = nil)
      result = Current.set(actor: "Reminders") { ReminderRunner.call(as_of: as_of&.to_date) }
      result.no_address.each do |reminder|
        Rails.logger.warn("Reminders: #{reminder.invoice.label} wasn't reminded: #{reminder.invoice.contact.name} has no email address")
      end
    end
  end
end
