# frozen_string_literal: true

module TudlaAccounting
  # Makes every organization's recurring entries due by today (RecurringEntryRunner). The
  # host app schedules it, e.g. daily with Solid Queue's config/recurring.yml:
  #
  #   recurring_entries:
  #     class: TudlaAccounting::RecurringEntriesJob
  #     schedule: every day at 1am
  #
  # Problems are kept on each template (last_problem) and logged; the job itself doesn't
  # fail, so the others still run.
  class RecurringEntriesJob < ApplicationJob
    queue_as :default

    def perform(as_of = nil)
      result = Current.set(actor: "Recurring entries") { RecurringEntryRunner.call(as_of: as_of&.to_date) }
      result.problems.each { |problem| Rails.logger.warn("Recurring entries: #{problem}") }
    end
  end
end
