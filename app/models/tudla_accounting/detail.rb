# frozen_string_literal: true

module TudlaAccounting
  class Detail < ApplicationRecord
    TALLY_DEBIT = "debit".freeze
    TALLY_CREDIT = "credit".freeze

    belongs_to :organization, polymorphic: true
    belongs_to :entry, class_name: "TudlaAccounting::Entry"
    belongs_to :account, class_name: "TudlaAccounting::Account"

    belongs_to :balance, class_name: "TudlaAccounting::Balance", optional: true

    has_one :foreign_exchange, class_name: "TudlaAccounting::ForeignExchange", dependent: :destroy
    has_one :carrying_amount, class_name: "TudlaAccounting::CarryingAmount", dependent: :destroy

    accepts_nested_attributes_for :foreign_exchange

    enum :tally, {
      TALLY_DEBIT.to_sym => 0,
      TALLY_CREDIT.to_sym => 1
    }

    monetize :amount_cents, with_model_currency: :currency

    scope :debits, -> { where(tally: TALLY_DEBIT) }
    scope :credits, -> { where(tally: TALLY_CREDIT) }

    def signed_amount
      @signed_amount ||= if account.debit_balance?
        tally == TALLY_DEBIT ? amount : -amount
      else
        tally == TALLY_DEBIT ? -amount : amount
      end
    end

    def post(posted_at)
      raise ArgumentError, "cannot post a detail without an entry" unless entry
      raise ArgumentError, "cannot post a detail without an account" unless account
      raise ArgumentError, "cannot post a detail without an amount" unless amount
      raise ArgumentError, "posted_at must be a datetime" unless posted_at.is_a?(Time) || posted_at.is_a?(ActiveSupport::TimeWithZone)

      transaction do
        periods = TudlaAccounting::Period.leaf_periods_for_date(organization, posted_at.to_date)

        raise ArgumentError, "no valid period found for the posted date" if periods.empty?
        raise ArgumentError, "multiple periods found for the posted date" if periods.count > 1

        balance = TudlaAccounting::Balance.get(account, periods.first)

        balance.post(amount, tally)

        self.balance = balance unless self.balance

        save!
        true
      end
    end
  end
end
