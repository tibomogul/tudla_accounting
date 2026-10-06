# frozen_string_literal: true

module TudlaAccounting
  class Account < ApplicationRecord
    belongs_to :organization, polymorphic: true
    has_ancestry orphan_strategy: :restrict, cache_depth: true, ancestry_format: :materialized_path2

    CATEGORY_ASSET = "asset".freeze
    CATEGORY_LIABILITY = "liability".freeze
    CATEGORY_EQUITY = "equity".freeze
    CATEGORY_INCOME = "income".freeze
    CATEGORY_EXPENSE = "expense".freeze

    enum :category, {
      CATEGORY_ASSET.to_sym => 0,
      CATEGORY_LIABILITY.to_sym => 1,
      CATEGORY_EQUITY.to_sym => 2,
      CATEGORY_INCOME.to_sym => 3,
      CATEGORY_EXPENSE.to_sym => 4
    }

    normalizes :currency, with: ->(currency) { currency.strip.upcase.presence }

    validates :name, :code, :category, presence: true
    validates :code, uniqueness: { scope: [ :organization_type, :organization_id ] }

    validate :validate_parent
    validate :validate_known_currency
    validate :validate_structure_unchanged_once_used, on: :update

    before_destroy :ensure_deletable, prepend: true
    after_create { audit("account.created") }
    after_update { audit("account.updated", changes: saved_changes.except("created_at", "updated_at")) if saved_changes.except("created_at", "updated_at").any? }
    after_destroy { audit("account.deleted") }

    has_many :balances, dependent: :destroy, class_name: "TudlaAccounting::Balance"
    has_many :details, dependent: :destroy, class_name: "TudlaAccounting::Detail"
    has_many :entries, through: :details, class_name: "TudlaAccounting::Entry"
    belongs_to :contra_account, class_name: "TudlaAccounting::Account", optional: true
    has_one :contra_for, class_name: "TudlaAccounting::Account", foreign_key: :contra_account_id
    has_one :bank_account_balance, class_name: "TudlaAccounting::BankAccountBalance", dependent: :destroy

    # Where its cash movements go in the cash flow statement. Blank inherits; see
    # cash_flow_section.
    enum :cash_flow_activity, { operating: 0, investing: 1, financing: 2 }, prefix: :cash_flow

    # The cash flow activity in effect: its own, else the nearest parent's, else financing
    # for equity accounts and operating for the rest.
    def cash_flow_section
      [ self, *ancestors.reverse ].find(&:cash_flow_activity)&.cash_flow_activity || (equity? ? "financing" : "operating")
    end

    def debit_balance?
      contra? ? (liability? || equity? || income?) : (asset? || expense?)
    end

    def balance_sheet_account?
      asset? || liability? || equity?
    end

    def code_with_name
      "#{code} - #{name}"
    end

    def contra?
      contra_account_id.present?
    end

    # Category, parent and contra account decide how balances add up, so they are fixed
    # once anything has been posted to the account.
    def structure_editable?
      details.none? && balances.none?
    end

    # Only an account with no history, no sub-accounts and nothing offsetting it.
    def deletable?
      structure_editable? && children.none? && contra_for.nil?
    end

    private

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end

    def validate_known_currency
      errors.add(:currency, "is not a known currency code") if currency.present? && Money::Currency.find(currency).nil?
    end

    def validate_structure_unchanged_once_used
      changed_structure = %w[category ancestry contra_account_id] & changed
      return if changed_structure.empty? || structure_editable?

      errors.add(:base, "Category, parent and contra account can't change once the account has postings")
    end

    def ensure_deletable
      return if deletable?

      errors.add(:base, "Only an account with no postings, sub-accounts or contra accounts can be deleted")
      throw :abort
    end

    def validate_parent
      return if parent_id.nil?

      errors.add(:base, "Attributes are not compatible with parent") if
        category != parent.category
    end
  end
end
