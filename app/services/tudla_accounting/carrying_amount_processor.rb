# frozen_string_literal: true

module TudlaAccounting
  # Creates or updates CarryingAmount records based on the role of an Entry's source
  # (see TudlaAccounting.configuration.carrying_amount_sources): receivables/payables
  # open a carrying amount, receipts/disbursements reduce it. Unmapped sources are ignored.
  class CarryingAmountProcessor
    def self.call(entry:)
      new(entry: entry).call
    end

    def initialize(entry:)
      @entry = entry
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
        related_party: @entry.organization
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
      method = TudlaAccounting.configuration.due_date_method
      source = @entry.source
      source.public_send(method) if method && source.respond_to?(method)
    end

    def update_receivable_carrying_amount
      invoice_entry = @entry.related
      return unless invoice_entry

      receivable_detail = invoice_entry.details.find { |d| IsAccountReceivableChecker.call(detail: d) }
      return unless receivable_detail

      carrying_amount = TudlaAccounting::CarryingAmount.find_by(detail_id: receivable_detail.id)
      return unless carrying_amount

      payment_detail = @entry.details.find { |d| IsAccountReceivableChecker.call(detail: d) }
      return unless payment_detail

      carrying_amount.amount_cents -= payment_detail.amount_cents

      if carrying_amount.forex
        payment_fx_detail = @entry.details.find(&:foreign_exchange)
        if payment_fx_detail
          foreign_cents = payment_fx_detail.foreign_exchange.other_currency_cents
          carrying_amount.forex.other_currency_amount_cents -= foreign_cents
          carrying_amount.forex.save!

          adjust_foreign_bank_account_balance(foreign_cents)
        end
      end

      carrying_amount.save!
      carrying_amount.reload
    end

    def update_payable_carrying_amount
      bill_entry = @entry.related
      return unless bill_entry

      payable_detail = bill_entry.details.find { |d| IsAccountPayableChecker.call(detail: d) }
      return unless payable_detail

      carrying_amount = TudlaAccounting::CarryingAmount.find_by(detail_id: payable_detail.id)
      return unless carrying_amount

      disbursement_detail = @entry.details.find { |d| IsAccountPayableChecker.call(detail: d) }
      return unless disbursement_detail

      carrying_amount.amount_cents -= disbursement_detail.amount_cents

      if carrying_amount.forex
        disbursement_fx_detail = @entry.details.find(&:foreign_exchange)
        if disbursement_fx_detail
          foreign_cents = disbursement_fx_detail.foreign_exchange.other_currency_cents
          carrying_amount.forex.other_currency_amount_cents -= foreign_cents
          carrying_amount.forex.save!

          adjust_foreign_bank_account_balance(-foreign_cents)
        end
      end

      carrying_amount.save!
      carrying_amount.reload
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
