# frozen_string_literal: true

module TudlaAccounting
  class CarryingAmount < ApplicationRecord
    belongs_to :detail, class_name: "TudlaAccounting::Detail"
    belongs_to :related_party, polymorphic: true
    has_one :forex, class_name: "TudlaAccounting::CarryingAmountForex", dependent: :destroy
    # As a credit: where it has been applied. As a charge: what has been applied to it.
    has_many :allocations_from, class_name: "TudlaAccounting::Allocation", foreign_key: :from_id, inverse_of: :from
    has_many :allocations_to, class_name: "TudlaAccounting::Allocation", foreign_key: :to_id, inverse_of: :to

    enum :carrying_amount_type, {
      receivable: 0,
      payable: 1
    }

    # In the currency of the line it was opened on (the organization's currency).
    def amount
      Money.new(amount_cents, detail.currency)
    end

    # A credit held by the customer or supplier (a payment, disbursement or credit note,
    # stored as a negative amount) rather than a charge they owe or are owed (an invoice
    # or bill): on the other side of the receivable or payable account.
    def credit?
      receivable? ? detail.credit? : detail.debit?
    end

    def charge?
      !credit?
    end

    # The allocations made from a credit, or to a charge.
    def allocations
      credit? ? allocations_from : allocations_to
    end

    # What is still owed (positive, on a charge) or still to apply (negative, on a credit),
    # in the organization's currency and, for a foreign amount, in the foreign currency, as
    # it stood at as_of (a time; nil for now). A charge starts at its line's amount and is
    # reduced by each allocation to it in force then, in order, settled at the rate it was
    # booked at (see settlement); a credit starts at minus its line's amount and goes back
    # towards zero by the credit each allocation used. Nothing is outstanding from the date
    # the entry itself is reversed.
    def outstanding(as_of: nil)
      return { cents: 0, foreign_cents: 0 } if reversed?(detail.entry, as_of)

      active = allocations.active(as_of).order(:allocated_at, :id)
      return { cents: -detail.amount_cents + active.sum(:amount_cents), foreign_cents: -opening_foreign_cents + active.sum(:other_currency_cents).to_i } if credit?

      remaining = detail.amount_cents
      remaining_foreign = opening_foreign_cents
      active.each do |allocation|
        if forex && allocation.other_currency_cents
          remaining -= settle(remaining, remaining_foreign, allocation.amount_cents, allocation.other_currency_cents)[:reduction_cents]
          remaining_foreign -= allocation.other_currency_cents
        else
          remaining -= allocation.amount_cents
        end
      end
      { cents: remaining, foreign_cents: remaining_foreign }
    end

    # How applying cash_cents of a credit for paid_foreign_cents of this charge's foreign
    # amount reduces it, given what was still owed; see settlement.
    def settle(remaining_cents, remaining_foreign_cents, cash_cents, paid_foreign_cents)
      self.class.settlement(remaining_cents: remaining_cents, remaining_foreign_cents: remaining_foreign_cents,
                            transaction_rate: forex.transaction_rate, foreign_currency: forex.other_currency,
                            currency: detail.currency, cash_cents: cash_cents, paid_foreign_cents: paid_foreign_cents)
    end

    # The foreign amount it opened with: its line's, or for a payment whose foreign amount
    # is on its bank line, that one.
    def opening_foreign_cents
      return 0 unless forex

      fx = detail.foreign_exchange || detail.entry.details.filter_map(&:foreign_exchange).first
      fx.other_currency_cents
    end

    # Brings the stored amounts in line with outstanding, e.g. after an allocation or a
    # reversal.
    def recompute!
      remaining = outstanding
      update!(amount_cents: remaining[:cents])
      forex&.update!(other_currency_amount_cents: remaining[:foreign_cents])
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

    private

    def reversed?(entry, as_of)
      reversal = entry.reversal
      reversal.present? && (as_of.nil? || reversal.transacted_at <= as_of)
    end
  end
end
