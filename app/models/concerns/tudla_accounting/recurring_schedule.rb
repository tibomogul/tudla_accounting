# frozen_string_literal: true

module TudlaAccounting
  # The schedule of a template made again and again (RecurringEntry, RecurringInvoice):
  # every interval weeks, months or years from starts_on. A monthly or yearly one falls on
  # day_of_month (the month's last day when the month is shorter), or on the last day of
  # the month when day_of_month is nil; a weekly one on starts_on's weekday. It stops after
  # ends_on, or once occurrences_limit have been made, when next_on becomes nil.
  #
  # The including model names the date of the last occurrence it made (last_made_on), so a
  # changed schedule picks up after it: nothing is made twice or skipped.
  module RecurringSchedule
    extend ActiveSupport::Concern

    FREQUENCIES = %w[weekly monthly yearly].freeze
    SCHEDULE = %w[frequency interval day_of_month starts_on ends_on occurrences_limit].freeze
    # Kept as it runs, apart from the template's own changes (and its audit trail).
    RUNNING = %w[created_at updated_at next_on occurrences_count last_problem].freeze

    included do
      validates :starts_on, presence: true
      validates :frequency, inclusion: { in: FREQUENCIES }
      validates :interval, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 120 }
      validates :day_of_month, numericality: { only_integer: true, in: 1..31 }, allow_nil: true
      validates :occurrences_limit, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
      validate :ends_after_start

      before_save :reschedule, if: -> { new_record? || (SCHEDULE & changed).any? }

      scope :active, -> { where(active: true) }
    end

    def due?(as_of)
      active? && next_on.present? && next_on <= as_of
    end

    def finished?
      next_on.nil?
    end

    # The first date of the schedule on or after date (ignoring when it stops).
    def first_on_or_after(date)
      date = [ date, starts_on ].max
      if frequency == "weekly"
        step = 7 * interval
        starts_on + (((date - starts_on).to_i + step - 1) / step) * step # whole days: a Rational would round nothing
      else
        months = frequency == "yearly" ? 12 * interval : interval
        (0..).lazy.map { |count| on_day(starts_on.beginning_of_month >> (count * months)) }.find { |candidate| candidate >= date }
      end
    end

    # Counts an occurrence made for on, and moves next_on to the one after (nil when the
    # schedule has run out). problem: what went wrong with it, if anything.
    def advance!(on, problem: nil)
      count = occurrences_count + 1
      update_columns(occurrences_count: count, next_on: following(first_on_or_after(on + 1), count), last_problem: problem, updated_at: Time.current)
    end

    # "Every month on the 1st", "Every 2 weeks", "Every year on the last day"...
    def schedule_label
      unit = { "weekly" => "week", "monthly" => "month", "yearly" => "year" }.fetch(frequency)
      every = interval == 1 ? "Every #{unit}" : "Every #{interval} #{unit}s"
      return "#{every} on #{starts_on.strftime('%A')}s" if frequency == "weekly"

      day = day_of_month ? day_of_month.ordinalize : "last day"
      frequency == "yearly" ? "#{every} on the #{day} of #{starts_on.strftime('%B')}" : "#{every} on the #{day}"
    end

    private

    def on_day(month_start)
      month_end = month_start.end_of_month
      day_of_month ? month_start.change(day: [ day_of_month, month_end.day ].min) : month_end
    end

    def following(date, count)
      return if occurrences_limit && count >= occurrences_limit
      return if ends_on && date > ends_on

      date
    end

    # next_on from the schedule: its first date, or after a change the first one after the
    # last occurrence made from it.
    def reschedule
      last_made = last_made_on if persisted?
      self.next_on = following(first_on_or_after(last_made ? last_made + 1 : starts_on), occurrences_count)
    end

    def ends_after_start
      errors.add(:ends_on, "must be on or after the start") if ends_on && starts_on && ends_on < starts_on
    end
  end
end
