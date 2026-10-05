# frozen_string_literal: true

module TudlaAccounting
  # Creates or updates CarryingAmount records based on the role of an Entry's source
  # (see TudlaAccounting.configuration.carrying_amount_sources): receivables/payables
  # open a carrying amount, receipts/disbursements reduce it. Unmapped sources are ignored.
  class CarryingAmountProcessor
    REALIZED_PREFIX = "Realized exchange ".freeze

    def self.call(entry:)
      new(entry: entry).call
    end

    def initialize(entry:)
      @entry = entry
    end

    # For a payment (or disbursement) that has just been reversed: undoes its change to a
    # foreign-currency bank balance and restores what it settled (recomputed from the
    # payments that still stand, since that depends on what was owed at the time).
    def undo_settlement
      checker, bank_sign = settlement_side
      return unless checker

      carrying_amount, _original_entry, settlement_detail = settled(checker)
      return unless carrying_amount

      fx_detail = carrying_amount.forex && (settlement_detail.foreign_exchange ? settlement_detail : @entry.details.find(&:foreign_exchange))
      adjust_foreign_bank_account_balance(-bank_sign * fx_detail.foreign_exchange.other_currency_cents) if fx_detail
      carrying_amount.recompute!
    end

    def call
      case CarryingAmountRole.call(entry: @entry)
      when :receivable then create_receivable_carrying_amount
      when :payable then create_payable_carrying_amount
      when :receipt then update_receivable_carrying_amount
      when :disbursement then update_payable_carrying_amount
      end
    end

    private

    def create_receivable_carrying_amount
      receivable_detail = @entry.details.find { |d| IsAccountReceivableChecker.call(detail: d) }
      return unless receivable_detail

      create_carrying_amount(receivable_detail, :receivable)
    end

    def create_payable_carrying_amount
      payable_detail = @entry.details.find { |d| IsAccountPayableChecker.call(detail: d) }
      return unless payable_detail

      create_carrying_amount(payable_detail, :payable)
    end

    def create_carrying_amount(detail, carrying_amount_type)
      carrying_amount = TudlaAccounting::CarryingAmount.create!(
        detail: detail,
        amount_cents: detail.amount_cents,
        carrying_amount_type: carrying_amount_type,
        due_date: due_date,
        related_party: related_party
      )

      fx = detail.foreign_exchange
      if fx
        carrying_amount.create_forex!(
          other_currency_amount_cents: fx.other_currency_cents,
          other_currency: fx.other_currency,
          transaction_rate: fx.rate,
          conversion_date: @entry.transacted_at
        )
      end

      carrying_amount
    end

    def due_date
      read_source(TudlaAccounting.configuration.due_date_method)
    end

    # The customer or supplier the amount is owed by or to, read from the source
    # (e.g. invoice.customer); the organization when not configured or not set.
    def related_party
      read_source(TudlaAccounting.configuration.related_party_method) || @entry.organization
    end

    def read_source(method)
      source = @entry.source
      source.public_send(method) if method && source.respond_to?(method)
    end

    def update_receivable_carrying_amount
      settle(IsAccountReceivableChecker, bank_sign: 1)
    end

    def update_payable_carrying_amount
      settle(IsAccountPayableChecker, bank_sign: -1)
    end

    # Reduces the carrying amount of the related invoice or bill by this payment or
    # disbursement. When it settles foreign currency, the carrying amount goes down by
    # the book value of the foreign amount owed that it settles (at the booked rate), and
    # the difference from the value paid for it is posted as a realized exchange gain or
    # loss; see CarryingAmount.settlement. An overpayment is left as a credit.
    def settlement_side
      case CarryingAmountRole.call(entry: @entry)
      when :receipt then [ IsAccountReceivableChecker, 1 ]
      when :disbursement then [ IsAccountPayableChecker, -1 ]
      end
    end

    # [carrying amount, the invoice or bill entry, this payment's line] for the related
    # invoice or bill this payment settles, or nil.
    def settled(checker)
      original_entry = @entry.related
      original_detail = original_entry&.details&.find { |d| checker.call(detail: d) }
      carrying_amount = original_detail && TudlaAccounting::CarryingAmount.find_by(detail_id: original_detail.id)
      settlement_detail = @entry.details.find { |d| checker.call(detail: d) }
      [ carrying_amount, original_entry, settlement_detail ] if carrying_amount && settlement_detail
    end

    def settle(checker, bank_sign:)
      carrying_amount, original_entry, settlement_detail = settled(checker)
      return unless carrying_amount

      fx_detail = carrying_amount.forex && (settlement_detail.foreign_exchange ? settlement_detail : @entry.details.find(&:foreign_exchange))
      if fx_detail
        forex = carrying_amount.forex
        foreign_cents = fx_detail.foreign_exchange.other_currency_cents
        settlement = TudlaAccounting::CarryingAmount.settlement(
          remaining_cents: carrying_amount.amount_cents, remaining_foreign_cents: forex.other_currency_amount_cents,
          transaction_rate: forex.transaction_rate, foreign_currency: forex.other_currency, currency: settlement_detail.currency,
          cash_cents: settlement_detail.amount_cents, paid_foreign_cents: foreign_cents
        )
        carrying_amount.amount_cents -= settlement[:reduction_cents]
        forex.update!(other_currency_amount_cents: forex.other_currency_amount_cents - foreign_cents)
        post_realized_gain_or_loss(carrying_amount, original_entry, settlement_detail, settlement[:realized_cents])
        adjust_foreign_bank_account_balance(bank_sign * foreign_cents)
      else
        carrying_amount.amount_cents -= settlement_detail.amount_cents
      end

      carrying_amount.save!
      carrying_amount.reload
    end

    # The payment's line moved the receivable/payable by the value paid; move it by the
    # difference so it reflects the book value settled, and recognize the difference.
    # Without a realized_fx_gain_account_code nothing is posted (and the difference stays
    # on the receivable/payable account).
    def post_realized_gain_or_loss(carrying_amount, original_entry, settlement_detail, difference_cents)
      return if difference_cents.zero?

      gain_account_code = TudlaAccounting.configuration.realized_fx_gain_account_code
      if gain_account_code.blank?
        Rails.logger.warn("TudlaAccounting: realized_fx_gain_account_code is not set; exchange difference on #{original_entry.particulars} not posted")
        return
      end

      currency = settlement_detail.currency
      difference = Money.new(difference_cents, currency)
      gain = carrying_amount.payable? ? -difference : difference # paying more for a liability is a loss
      entry = TudlaAccounting::Entry.create_from_ruby_hash(
        organization_type: @entry.organization_type, organization_id: @entry.organization_id,
        particulars: "#{REALIZED_PREFIX}#{gain.positive? ? 'gain' : 'loss'} on #{original_entry.particulars}",
        transacted_at: (@entry.posted_at || @entry.transacted_at).iso8601,
        details: [ { account_code: settlement_detail.account.code, amount: "#{currency} #{difference}" },
                   { account_code: gain_account_code, amount: "#{currency} #{gain}" } ]
      )
      entry.update!(related: @entry) # no source, so posting it opens or settles nothing
      entry.post(entry.transacted_at)
    end

    # Money received into / paid out of a non-base-currency bank account also
    # moves that account's balance in its own currency.
    def adjust_foreign_bank_account_balance(foreign_cents)
      bank_detail = @entry.details.find { |d| d.account.bank_account_balance.present? }
      return unless bank_detail

      bank_account_balance = bank_detail.account.bank_account_balance
      return if bank_account_balance.currency == TudlaAccounting.configuration.base_currency

      bank_account_balance.update!(balance_cents: bank_account_balance.balance_cents + foreign_cents)
    end
  end
end
