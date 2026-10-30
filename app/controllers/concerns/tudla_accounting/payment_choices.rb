module TudlaAccounting
  # The bank and cash accounts payments go through, and the currencies they can be in, for
  # the payment forms and the pay run.
  module PaymentChoices
    extend ActiveSupport::Concern

    included do
      helper_method :payment_accounts, :payment_currencies, :bank_accounts
    end

    private

    # The bank and cash accounts a payment in a currency can go through (in the
    # organization's, those held in no other).
    def payment_accounts(currency = accounting_organization.currency)
      held = currency == accounting_organization.currency ? [ nil, currency ] : currency
      bank_accounts.where(currency: held)
    end

    # The currencies payments can be in: the organization's, and those of its other bank
    # accounts.
    def payment_currencies
      [ accounting_organization.currency, *bank_accounts.where.not(currency: [ nil, accounting_organization.currency ]).reorder(nil).distinct.pluck(:currency).sort ]
    end

    # Active asset and liability accounts without sub-accounts, other than receivables and
    # payables (and their sub-accounts).
    def bank_accounts
      control = organization_scope(Account).where(role: %w[receivable payable]).flat_map(&:subtree_ids)
      organization_scope(Account).active.postable.where(category: [ Account::CATEGORY_ASSET, Account::CATEGORY_LIABILITY ]).where.not(id: control).order(:code)
    end

    # The account in the currency the last payment went through, or the first cash account
    # (in a foreign currency, the first account held in it).
    def default_account_id(currency)
      accounts = payment_accounts(currency)
      last = organization_scope(Payment).order(:id).last&.account_id
      return last if last && accounts.exists?(id: last)

      accounts.where(code: TudlaAccounting.configuration.cash_account_codes_for(accounting_organization)).first&.id ||
        (accounts.first&.id unless currency == accounting_organization.currency)
    end
  end
end
