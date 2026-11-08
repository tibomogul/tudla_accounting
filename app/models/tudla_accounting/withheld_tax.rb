# frozen_string_literal: true

module TudlaAccounting
  # An amount of tax withheld, as posted, which the withholding reports read: from a
  # supplier on a bill's line (negative on a supplier credit's), or by a customer from a
  # payment, in the organization's currency, with the amount it was withheld from. Its
  # amounts don't change: reversing what posted it adds an opposite row dated then
  # (reversal), so what was certified for an earlier quarter stays as it was and each
  # quarter's rows add up to the account's movement in it.
  #
  # All that changes is when the customer's certificate came in, certificate_received_on.
  class WithheldTax < ApplicationRecord
    DIRECTIONS = %w[from_supplier by_customer].freeze

    include OrganizationOwned
    belongs_to :contact, class_name: "TudlaAccounting::Contact"
    belongs_to :withholding_code, class_name: "TudlaAccounting::WithholdingCode"
    belongs_to :entry, class_name: "TudlaAccounting::Entry"
    belongs_to :document_line, class_name: "TudlaAccounting::DocumentLine", optional: true
    belongs_to :payment, class_name: "TudlaAccounting::Payment", optional: true

    validates :direction, inclusion: { in: DIRECTIONS }
    validates :on, :base_cents, :withheld_cents, presence: true
    validate :only_the_certificate_changes, on: :update

    before_destroy { throw :abort }

    scope :by_customer, -> { where(direction: "by_customer") }
    # Not reversed, nor a reversal itself.
    scope :standing, -> { where(reversal: false).where.not(entry_id: unscoped.where(reversal: true).select(:entry_id)) }
    scope :certificate_waiting, -> { standing.by_customer.where(certificate_received_on: nil) }
    scope :certificate_received, -> { standing.by_customer.where.not(certificate_received_on: nil) }

    # Adds the opposite of each row its entry made, dated on.
    def self.reverse!(entry, on:)
      where(entry: entry, reversal: false).find_each do |row|
        create!(row.attributes.slice("organization_type", "organization_id", "contact_id", "withholding_code_id", "entry_id", "document_line_id", "payment_id", "direction")
                   .merge(on: on, base_cents: -row.base_cents, withheld_cents: -row.withheld_cents, reversal: true))
      end
    end

    # Marks each row's certificate received on a day; all or none.
    def self.mark_certificates!(rows, on:)
      transaction { rows.each { |row| row.mark_certificate!(on: on) } }
    end

    def reversed? = reversal || self.class.where(entry_id: entry_id, reversal: true).exists?
    def certificate_received? = certificate_received_on.present?

    def mark_certificate!(on:)
      raise ArgumentError, "Only tax a customer withheld has a certificate to receive" unless direction == "by_customer"
      raise ArgumentError, "This amount has been reversed" if reversed?
      raise ArgumentError, "This certificate is marked received already" if certificate_received?
      raise ArgumentError, "Give the day the certificate came in" if on.blank?

      transaction do
        update!(certificate_received_on: on)
        AuditEvent.record!("withheld_tax.certificate_received", organization: organization, subject: payment, details: certificate_details.merge(on: on.to_date.iso8601))
      end
    end

    def unmark_certificate!
      raise ArgumentError, "This certificate isn't marked received" unless certificate_received?

      transaction do
        update!(certificate_received_on: nil)
        AuditEvent.record!("withheld_tax.certificate_unmarked", organization: organization, subject: payment, details: certificate_details)
      end
    end

    private

    def certificate_details = { code: withholding_code.code, withheld_cents: withheld_cents }

    def only_the_certificate_changes
      errors.add(:base, "An amount of tax withheld can't be changed; reverse what posted it") if (changed - %w[certificate_received_on]).any?
    end
  end
end
