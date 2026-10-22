# frozen_string_literal: true

module TudlaAccounting
  # An invoice made again and again (a retainer, a subscription): its customer, lines,
  # reference and notes, and a schedule (RecurringSchedule). RecurringInvoiceRunner makes
  # each occurrence's invoice when it falls due and moves next_on on. What it does with
  # each (issue): leaves it a draft to check and approve, approves it, or approves it and
  # emails it to the customer.
  #
  # Each invoice is dated the day it falls due, and due due_days later (or on the
  # customer's payment terms when due_days is nil). Its lines are the template's, their
  # dimension values too. It is made with "recurring_invoice:<id>:<date>" as its
  # idempotency key and the template as its recurring_invoice, so no date is made twice.
  class RecurringInvoice < ApplicationRecord
    include RecurringSchedule

    ISSUES = {
      "draft" => "Drafts to check and approve",
      "approve" => "Approved invoices",
      "email" => "Approved invoices, emailed to the customer"
    }.freeze

    belongs_to :organization, polymorphic: true
    belongs_to :contact, class_name: "TudlaAccounting::Contact"
    has_many :lines, -> { order(:position, :id) }, class_name: "TudlaAccounting::RecurringInvoiceLine", dependent: :destroy, inverse_of: :recurring_invoice
    # Deleting the template leaves them, unlinked (the foreign key nullifies).
    has_many :invoices, class_name: "TudlaAccounting::Document", inverse_of: :recurring_invoice

    accepts_nested_attributes_for :lines, allow_destroy: true

    normalizes :reference, with: ->(reference) { reference.strip.presence }
    normalizes :notes, with: ->(notes) { notes.strip.presence }

    validates :name, presence: true, length: { maximum: 255 }
    validates :issue, inclusion: { in: ISSUES.keys }
    validates :due_days, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 3_650 }, allow_nil: true
    validate :lines_make_an_invoice

    after_create { audit("recurring_invoice.created") }
    after_update { audit("recurring_invoice.updated", changes: saved_changes.except(*RUNNING)) if (saved_changes.keys - RUNNING).any? }
    after_destroy { audit("recurring_invoice.deleted") }

    def sales? = true # its invoices are, for the invoice form's choices
    def issue_label = ISSUES.fetch(issue)
    def approves? = issue != "draft"
    def emails? = issue == "email"

    # The draft invoice for a date (unsaved), numbered and posted only once approved. (Linked
    # by id: through the association it would join invoices, and be saved with the template.)
    def build_invoice(on:)
      Document.new(organization: organization, kind: "sales_invoice", contact: contact, recurring_invoice_id: id,
                   issued_on: on, due_on: due_days ? on + due_days : contact&.due_on(on), reference: reference, notes: notes,
                   tax_inclusive: tax_inclusive?, idempotency_key: (idempotency_key(on) if persisted?),
                   lines_attributes: live_lines.each_with_index.map { |line, index| line.document_line_attributes.merge(position: index) })
    end

    def idempotency_key(on) = "recurring_invoice:#{id}:#{on.iso8601}"

    # Each invoice's total, tax included, worked out as the invoice's is.
    def total
      cents = live_lines.sum do |line|
        amount = line.amount_cents
        tax = line.tax_code ? line.tax_code.tax_cents(amount, inclusive: tax_inclusive?) : 0
        tax_inclusive? ? amount : amount + tax
      end
      Money.new(cents, organization&.currency || TudlaAccounting.configuration.base_currency)
    end

    private

    def live_lines = lines.reject(&:marked_for_destruction?)

    def last_made_on
      invoices.maximum(:issued_on)
    end

    # The lines must make an invoice that could be saved: the customer one, every account
    # and tax code usable on an invoice, the dimensions known. A customer made inactive
    # since doesn't stop the template being changed (or made inactive too).
    def lines_make_an_invoice
      return errors.add(:base, "Add at least one line") if live_lines.empty?
      return if contact.nil?

      invoice = build_invoice(on: starts_on || Date.current)
      invoice.valid?
      invoice.errors.each do |error|
        next if error.attribute == :contact && error.type == "is inactive" && !will_save_change_to_contact_id?

        error.attribute == :contact ? errors.add(:contact, error.message) : errors.add(:base, error.full_message)
      end
    end

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end
  end
end
