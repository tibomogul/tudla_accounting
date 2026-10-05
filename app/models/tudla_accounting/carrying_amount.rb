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

    # What is still owed, in the organization's currency and (for a foreign amount) in the
    # foreign currency: the amount as booked, less each payment (or disbursement) posted
    # against it by as_of (a time; nil for everything), settled the way the processor
    # settles them. A reversed payment stops counting from its reversal's date, and the
    # whole amount stops being owed from the date the invoice or bill itself is reversed.
    def outstanding(as_of: nil)
      opening = detail.entry
      return { cents: 0, foreign_cents: 0 } if reversed?(opening, as_of)

      remaining = detail.amount_cents
      remaining_foreign = detail.foreign_exchange&.other_currency_cents.to_i
      settlements(as_of: as_of).each do |line, fx|
        if forex && fx
          remaining -= self.class.settlement(remaining_cents: remaining, remaining_foreign_cents: remaining_foreign,
                                             transaction_rate: forex.transaction_rate, foreign_currency: forex.other_currency,
                                             currency: line.currency, cash_cents: line.amount_cents,
                                             paid_foreign_cents: fx.other_currency_cents)[:reduction_cents]
          remaining_foreign -= fx.other_currency_cents
        else
          remaining -= line.amount_cents
        end
      end
      { cents: remaining, foreign_cents: remaining_foreign }
    end

    # [settlement line, its foreign exchange] for each payment (or disbursement) posted
    # against the invoice or bill by as_of and not reversed by then, in order. Revaluations,
    # which are also related to it, are not settlements.
    def settlements(as_of: nil)
      role = receivable? ? :receipt : :disbursement
      checker = receivable? ? IsAccountReceivableChecker : IsAccountPayableChecker
      payments = TudlaAccounting::Entry.where(related: detail.entry).where.not(posted_at: nil)
      payments = payments.where(transacted_at: ..as_of) if as_of
      payments.includes(details: %i[account foreign_exchange]).order(:transacted_at, :id)
        .select { |payment| CarryingAmountRole.call(entry: payment) == role && !reversed?(payment, as_of) }
        .filter_map do |payment|
          line = payment.details.find { |candidate| checker.call(detail: candidate) }
          [ line, line.foreign_exchange || payment.details.filter_map(&:foreign_exchange).first ] if line
        end
    end

    # Brings the stored amounts in line with outstanding, e.g. after a reversal.
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
