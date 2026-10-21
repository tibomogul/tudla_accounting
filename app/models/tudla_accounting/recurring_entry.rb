# frozen_string_literal: true

module TudlaAccounting
  # An entry made again and again (rent, a subscription, depreciation): its particulars and
  # lines, and a schedule. RecurringEntryRunner makes each occurrence's entry when it falls
  # due, as a draft or (post_automatically) posted, and moves next_on on.
  #
  # The schedule runs every interval weeks, months or years from starts_on. A monthly or
  # yearly one falls on day_of_month (the month's last day when the month is shorter), or
  # on the last day of the month when day_of_month is nil; a weekly one on starts_on's
  # weekday. It stops after ends_on, or once occurrences_limit entries have been made, when
  # next_on becomes nil.
  #
  # Lines are kept like an entry's, against accounts (not their codes), with an optional
  # tax code (tax added, or included with tax_inclusive) and dimension values. Each entry
  # is made through Entry.create_from_ruby_hash, so it is checked as any entry is, with
  # the template as its source and "recurring:<id>:<date>" as its idempotency key: running
  # twice never makes an occurrence twice. With reverse_next_month, each entry reverses
  # itself on the first day of the next month (an accrual).
  class RecurringEntry < ApplicationRecord
    FREQUENCIES = %w[weekly monthly yearly].freeze
    SCHEDULE = %w[frequency interval day_of_month starts_on ends_on occurrences_limit].freeze

    belongs_to :organization, polymorphic: true
    has_many :lines, -> { order(:id) }, class_name: "TudlaAccounting::RecurringEntryLine", dependent: :destroy, inverse_of: :recurring_entry
    has_many :entries, as: :source, class_name: "TudlaAccounting::Entry"

    accepts_nested_attributes_for :lines, allow_destroy: true

    normalizes :reference, with: ->(reference) { reference.strip.presence }

    validates :name, :particulars, :starts_on, presence: true
    validates :frequency, inclusion: { in: FREQUENCIES }
    validates :interval, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 120 }
    validates :day_of_month, numericality: { only_integer: true, in: 1..31 }, allow_nil: true
    validates :occurrences_limit, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validate :ends_after_start
    validate :lines_make_an_entry

    before_save :reschedule, if: -> { new_record? || (SCHEDULE & changed).any? }
    after_create { audit("recurring_entry.created") }
    after_update { audit("recurring_entry.updated", changes: saved_changes.except("created_at", "updated_at", "next_on", "occurrences_count", "last_problem")) if (saved_changes.keys - %w[created_at updated_at next_on occurrences_count last_problem]).any? }
    after_destroy { audit("recurring_entry.deleted") }

    scope :active, -> { where(active: true) }

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
        starts_on + (((date - starts_on) + step - 1) / step) * step
      else
        months = frequency == "yearly" ? 12 * interval : interval
        (0..).lazy.map { |count| on_day(starts_on.beginning_of_month >> (count * months)) }.find { |candidate| candidate >= date }
      end
    end

    # Counts an occurrence made for on, and moves next_on to the one after (nil when the
    # schedule has run out). problem: why its entry was left as a draft, if it was.
    def advance!(on, problem: nil)
      count = occurrences_count + 1
      update_columns(occurrences_count: count, next_on: following(first_on_or_after(on + 1), count), last_problem: problem, updated_at: Time.current)
    end

    # The hash Entry.create_from_ruby_hash takes for the entry on a date.
    def entry_hash(on:)
      zone = ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone]
      { organization_type: organization_type, organization_id: organization_id, particulars: particulars, reference: reference,
        transacted_at: zone.local(on.year, on.month, on.day).iso8601, tax_inclusive: tax_inclusive?,
        reverse_on: (on.next_month.beginning_of_month.iso8601 if reverse_next_month?),
        source_type: self.class.name, source_id: id, idempotency_key: ("recurring:#{id}:#{on.iso8601}" if id),
        details: lines.reject(&:marked_for_destruction?).map { |line| line.detail_hash(organization.currency) } }
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
    # last entry made from it (so nothing is made twice or skipped).
    def reschedule
      last_made = entries.maximum(:transacted_at)&.in_time_zone(TudlaAccounting.configuration.time_zone)&.to_date if persisted?
      self.next_on = following(first_on_or_after(last_made ? last_made + 1 : starts_on), occurrences_count)
    end

    def ends_after_start
      errors.add(:ends_on, "must be on or after the start") if ends_on && starts_on && ends_on < starts_on
    end

    # The lines must make an entry that could be posted: balanced, at least one debit and
    # one credit, every account active, tax codes and dimensions known.
    def lines_make_an_entry
      return errors.add(:base, "Add at least one debit and one credit line") if lines.reject(&:marked_for_destruction?).size < 2
      return if lines.any? { |line| line.account.nil? || !line.valid? }

      entry = Entry.build_from_ruby_hash(entry_hash(on: starts_on || Date.current).merge(reverse_on: nil))
      entry.valid?
      entry.errors[:base].each { |message| errors.add(:base, message) }
    rescue ArgumentError => e
      errors.add(:base, e.message.upcase_first)
    end

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end
  end
end
