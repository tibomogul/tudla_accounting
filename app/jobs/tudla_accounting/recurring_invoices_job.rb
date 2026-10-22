# frozen_string_literal: true

module TudlaAccounting
  # Makes every organization's recurring invoices due by today (RecurringInvoiceRunner),
  # as "Recurring invoices" on the audit trail. The host app schedules it, e.g. daily with
  # Solid Queue's config/recurring.yml:
  #
  #   recurring_invoices:
  #     class: TudlaAccounting::RecurringInvoicesJob
  #     schedule: every day at 1am
  #
  # Problems are kept on each template (last_problem) and logged; the job itself doesn't
  # fail, so the others still run.
  class RecurringInvoicesJob < ApplicationJob
    queue_as :default

    def perform(as_of = nil)
      result = Current.set(actor: "Recurring invoices") { RecurringInvoiceRunner.call(as_of: as_of&.to_date) }
      result.problems.each { |problem| Rails.logger.warn("Recurring invoices: #{problem}") }
    end
  end
end
