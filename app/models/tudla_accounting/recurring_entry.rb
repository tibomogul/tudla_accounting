# frozen_string_literal: true

module TudlaAccounting
  # An entry made again and again (rent, a subscription, depreciation): its particulars and
  # lines, and a schedule (RecurringSchedule). RecurringEntryRunner makes each occurrence's
  # entry when it falls due, as a draft or (post_automatically) posted, and moves next_on on.
  #
  # Lines are kept like an entry's, against accounts (not their codes), with an optional
  # tax code (tax added, or included with tax_inclusive) and dimension values. Each entry
  # is made through Entry.create_from_ruby_hash, so it is checked as any entry is, with
  # the template as its source and "recurring:<id>:<date>" as its idempotency key: running
  # twice never makes an occurrence twice. With reverse_next_month, each entry reverses
  # itself on the first day of the next month (an accrual).
  class RecurringEntry < ApplicationRecord
    include RecurringSchedule

    belongs_to :organization, polymorphic: true
    has_many :lines, -> { order(:id) }, class_name: "TudlaAccounting::RecurringEntryLine", dependent: :destroy, inverse_of: :recurring_entry
    has_many :entries, as: :source, class_name: "TudlaAccounting::Entry"

    accepts_nested_attributes_for :lines, allow_destroy: true

    normalizes :reference, with: ->(reference) { reference.strip.presence }

    validates :name, :particulars, presence: true
    validate :lines_make_an_entry

    after_create { audit("recurring_entry.created") }
    after_update { audit("recurring_entry.updated", changes: saved_changes.except(*RUNNING)) if (saved_changes.keys - RUNNING).any? }
    after_destroy { audit("recurring_entry.deleted") }

    # The hash Entry.create_from_ruby_hash takes for the entry on a date.
    def entry_hash(on:)
      zone = ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone]
      { organization_type: organization_type, organization_id: organization_id, particulars: particulars, reference: reference,
        transacted_at: zone.local(on.year, on.month, on.day).iso8601, tax_inclusive: tax_inclusive?,
        reverse_on: (on.next_month.beginning_of_month.iso8601 if reverse_next_month?),
        source_type: self.class.name, source_id: id, idempotency_key: ("recurring:#{id}:#{on.iso8601}" if id),
        details: lines.reject(&:marked_for_destruction?).map { |line| line.detail_hash(organization.currency) } }
    end

    private

    def last_made_on
      entries.maximum(:transacted_at)&.in_time_zone(TudlaAccounting.configuration.time_zone)&.to_date
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
