# frozen_string_literal: true

module TudlaAccounting
  class CarryingAmount < ApplicationRecord
    belongs_to :detail, class_name: "TudlaAccounting::Detail"
    belongs_to :related_party, polymorphic: true
    has_one :forex, class_name: "TudlaAccounting::CarryingAmountForex", dependent: :destroy

    enum :carrying_amount_type, {
      receivable: 0,
      payable: 1
    }

    # In the currency of the line it was opened on (the organization's currency).
    def amount
      Money.new(amount_cents, detail.currency)
    end

    # How a payment of cash_cents (organization currency) for paid_foreign_cents of a
    # foreign-currency amount reduces it, given what was still owed. Only the foreign
    # amount actually owed is settled, at the rate it was booked at; the difference from
    # the cash paid for it is a realized gain (positive) or loss in the account's own
    # terms. Any overpayment reduces the amount at the cash value, leaving a credit.
    # Settling all that is owed settles all of the remaining book value (no rounding
    # residue). Returns { reduction_cents:, realized_cents: }.
    def self.settlement(remaining_cents:, remaining_foreign_cents:, transaction_rate:, foreign_currency:, currency:,
                        cash_cents:, paid_foreign_cents:)
      settled_foreign = paid_foreign_cents.clamp(0, [ remaining_foreign_cents, 0 ].max)
      book_cents = if settled_foreign.positive? && settled_foreign == remaining_foreign_cents
        remaining_cents
      else
        Money.from_amount(Money.new(settled_foreign, foreign_currency).to_d * transaction_rate, currency).cents
      end
      cash_for_settled = paid_foreign_cents.positive? ? (BigDecimal(cash_cents) * settled_foreign / paid_foreign_cents).round.to_i : cash_cents

      { reduction_cents: book_cents + (cash_cents - cash_for_settled), realized_cents: cash_for_settled - book_cents }
    end
  end
end
