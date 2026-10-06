# frozen_string_literal: true

module TudlaAccounting
  class Detail < ApplicationRecord
    TALLY_DEBIT = "debit".freeze
    TALLY_CREDIT = "credit".freeze

    belongs_to :organization, polymorphic: true
    belongs_to :entry, class_name: "TudlaAccounting::Entry"
    belongs_to :account, class_name: "TudlaAccounting::Account"

    belongs_to :balance, class_name: "TudlaAccounting::Balance", optional: true
    # Taxed under a code: the line the tax is on (base), or the tax itself (tax).
    belongs_to :tax_code, class_name: "TudlaAccounting::TaxCode", optional: true
    enum :tax_role, { base: 0, tax: 1 }, prefix: :tax

    has_one :foreign_exchange, class_name: "TudlaAccounting::ForeignExchange", dependent: :destroy
    has_one :carrying_amount, class_name: "TudlaAccounting::CarryingAmount", dependent: :destroy

    accepts_nested_attributes_for :foreign_exchange

    enum :tally, {
      TALLY_DEBIT.to_sym => 0,
      TALLY_CREDIT.to_sym => 1
    }

    monetize :amount_cents, with_model_currency: :currency

    validates :amount_cents, numericality: { greater_than: 0, message: "must be more than zero" }
    validates :tax_role, presence: true, if: :tax_code
    validate :tax_code_fits

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
        lock_organization!
        periods = TudlaAccounting::Period.leaf_periods_for_date(organization, posted_at)

        raise ArgumentError, "no valid period found for the posted date" if periods.empty?
        raise ArgumentError, "multiple periods found for the posted date" if periods.count > 1
        raise ArgumentError, "the period for the posted date is closed" if periods.first.closed?

        balance = TudlaAccounting::Balance.get(account, periods.first)

        balance.post(amount, tally)

        self.balance = balance unless self.balance

        save!
        true
      end
    end

    private

    def tax_code_fits
      return unless tax_code

      errors.add(:tax_code, "must belong to the same organization") if tax_code.organization_type != organization_type || tax_code.organization_id != organization_id
      errors.add(:account, "must be the tax code's account for a tax line") if tax_tax? && account_id != tax_code.account_id
    end
  end
end
