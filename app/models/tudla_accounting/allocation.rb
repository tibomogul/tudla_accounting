# frozen_string_literal: true

module TudlaAccounting
  # Part of a credit (a payment, disbursement or credit note: `from`) applied to what is
  # owed on an invoice or bill (`to`), from allocated_at until it is unapplied
  # (reversed_at). amount_cents is the credit used, in the organization's currency;
  # other_currency_cents the foreign amount, when the credit is in a foreign currency.
  # Made and undone through TudlaAccounting::Allocator.
  class Allocation < ApplicationRecord
    belongs_to :organization, polymorphic: true
    belongs_to :from, class_name: "TudlaAccounting::CarryingAmount"
    belongs_to :to, class_name: "TudlaAccounting::CarryingAmount"
    belongs_to :realized_entry, class_name: "TudlaAccounting::Entry", optional: true

    validates :amount_cents, numericality: { greater_than: 0 }

    # Allocations in force at as_of (a time; nil for now).
    scope :active, ->(as_of = nil) {
      next where(reversed_at: nil) unless as_of

      made = where(allocated_at: ..as_of)
      made.where(reversed_at: nil).or(made.where.not(reversed_at: ..as_of))
    }

    def active?
      reversed_at.nil?
    end

    def amount
      Money.new(amount_cents, from.detail.currency)
    end

    # "Payment 7 to Invoice 1001"
    def label
      "#{from.detail.entry.particulars} to #{to.detail.entry.particulars}"
    end
  end
end
