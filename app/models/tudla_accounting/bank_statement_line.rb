# frozen_string_literal: true

module TudlaAccounting
  # One transaction on a bank statement, imported for a bank account (see
  # BankStatementImporter): money in is positive, money out negative, in the account's
  # currency. It is reconciled once it is matched to the posted ledger lines it stands
  # for (see BankReconciler).
  class BankStatementLine < ApplicationRecord
    belongs_to :organization, polymorphic: true
    belongs_to :account, class_name: "TudlaAccounting::Account"
    has_many :bank_matches, class_name: "TudlaAccounting::BankMatch", dependent: :destroy
    has_many :details, through: :bank_matches, class_name: "TudlaAccounting::Detail"

    validates :occurred_on, :description, :currency, :external_id, presence: true
    validates :amount_cents, numericality: { other_than: 0 }

    scope :unmatched, -> { where.missing(:bank_matches) }

    def amount
      Money.new(amount_cents, currency)
    end

    def balance
      balance_cents && Money.new(balance_cents, currency)
    end

    def matched?
      bank_matches.any?
    end

    # "3 Mar 2026 Bank fee (5.00)"
    def label
      "#{occurred_on.strftime('%-d %b %Y')} #{description} #{amount_cents.negative? ? "(#{amount.abs.format(symbol: false)})" : amount.format(symbol: false)}"
    end
  end
end
