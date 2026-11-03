# frozen_string_literal: true

module TudlaAccounting
  # An amount of tax withheld, as posted, which the withholding reports read: from a
  # supplier on a bill's line (negative on a supplier credit's), in the organization's
  # currency, with the amount it was withheld from. It doesn't change: reversing what
  # posted it adds an opposite row dated then (reversal), so what was certified for an
  # earlier quarter stays as it was and each quarter's rows add up to the account's
  # movement in it.
  class WithheldTax < ApplicationRecord
    DIRECTIONS = %w[from_supplier by_customer].freeze

    belongs_to :organization, polymorphic: true
    belongs_to :contact, class_name: "TudlaAccounting::Contact"
    belongs_to :withholding_code, class_name: "TudlaAccounting::WithholdingCode"
    belongs_to :entry, class_name: "TudlaAccounting::Entry"
    belongs_to :document_line, class_name: "TudlaAccounting::DocumentLine", optional: true

    validates :direction, inclusion: { in: DIRECTIONS }
    validates :on, :base_cents, :withheld_cents, presence: true

    # Adds the opposite of each row its entry made, dated on.
    def self.reverse!(entry, on:)
      where(entry: entry, reversal: false).find_each do |row|
        create!(row.attributes.slice("organization_type", "organization_id", "contact_id", "withholding_code_id", "entry_id", "document_line_id", "direction")
                   .merge(on: on, base_cents: -row.base_cents, withheld_cents: -row.withheld_cents, reversal: true))
      end
    end

    def readonly? = persisted?
  end
end
