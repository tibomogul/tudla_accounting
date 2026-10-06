# frozen_string_literal: true

module TudlaAccounting
  # Creates CarryingAmount records based on the role of an Entry's source (see
  # TudlaAccounting.configuration.carrying_amount_sources): invoices and bills
  # (receivable/payable) open what is owed; payments, disbursements and credit notes open a
  # credit, applied to the invoice or bill they are related to. Unmapped sources are ignored.
  class CarryingAmountProcessor
    REALIZED_PREFIX = "Realized exchange ".freeze

    def self.call(entry:)
      new(entry: entry).call
    end

    # side_effects: false only opens the carrying amount (see AllocationBackfill).
    def initialize(entry:, side_effects: true)
      @entry = entry
      @side_effects = side_effects
    end

    # For a credit (payment, disbursement or credit note) that has just been reversed:
    # takes it off what it was applied to and undoes its change to a foreign-currency
    # bank balance.
    def undo_credit(on)
      _checker, bank_sign = credit_side
      credit = credit_line&.carrying_amount
      return unless credit

      credit.allocations_from.active.each { |allocation| Allocator.unallocate!(allocation, at: on) }
      adjust_foreign_bank_account_balance(-bank_sign * credit_foreign_cents) if credit_foreign_cents
    end

    def call
      case CarryingAmountRole.call(entry: @entry)
      when :receivable then create_receivable_carrying_amount
      when :payable then create_payable_carrying_amount
      when :receipt, :credit_note then open_credit(:receivable)
      when :disbursement, :supplier_credit then open_credit(:payable)
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

    # A payment, disbursement or credit note opens a credit for the customer or supplier on
    # its receivable or payable line (a negative carrying amount), moves a foreign-currency
    # bank balance by the foreign amount paid, and is applied to the invoice or bill it is
    # related to, as far as that is still owed. Whatever is left stays as a credit to apply
    # later (see Allocator).
    def open_credit(type)
      checker, bank_sign = credit_side
      line = credit_line
      return unless line && (type == :receivable ? line.credit? : line.debit?)

      credit = TudlaAccounting::CarryingAmount.create!(detail: line, amount_cents: -line.amount_cents, carrying_amount_type: type,
                                                       related_party: read_source(TudlaAccounting.configuration.related_party_method) ||
                                                                      related_charge(checker)&.related_party || @entry.organization)
      fx = line.foreign_exchange || @entry.details.filter_map(&:foreign_exchange).first
      if fx
        credit.create_forex!(other_currency_amount_cents: -fx.other_currency_cents, other_currency: fx.other_currency,
                             transaction_rate: fx.rate, conversion_date: @entry.transacted_at)
        adjust_foreign_bank_account_balance(bank_sign * fx.other_currency_cents) if @side_effects
      end

      charge = related_charge(checker)
      if @side_effects && charge&.amount_cents&.positive? && charge.related_party == credit.related_party && !charge.detail.entry.reversal
        Allocator.allocate!(credit, charge, at: @entry.posted_at || @entry.transacted_at)
      end
      credit
    end

    def credit_side
      case CarryingAmountRole.call(entry: @entry)
      when :receipt, :credit_note then [ IsAccountReceivableChecker, 1 ]
      when :disbursement, :supplier_credit then [ IsAccountPayableChecker, -1 ]
      end
    end

    def credit_line
      checker, = credit_side
      checker && @entry.details.find { |d| checker.call(detail: d) }
    end

    def credit_foreign_cents
      (credit_line.foreign_exchange || @entry.details.filter_map(&:foreign_exchange).first)&.other_currency_cents
    end

    # The invoice or bill this entry is related to, if it opened one.
    def related_charge(checker)
      related = @entry.related
      return unless related.is_a?(TudlaAccounting::Entry)

      related.details.find { |d| checker.call(detail: d) }&.carrying_amount
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
