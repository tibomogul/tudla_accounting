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

    validates :name, :code, :category, presence: true

    validate :validate_parent

    has_many :balances, dependent: :destroy, class_name: "TudlaAccounting::Balance"
    has_many :details, dependent: :destroy, class_name: "TudlaAccounting::Detail"
    has_many :entries, through: :details, class_name: "TudlaAccounting::Entry"
    belongs_to :contra_account, class_name: "TudlaAccounting::Account", optional: true
    has_one :contra_for, class_name: "TudlaAccounting::Account", foreign_key: :contra_account_id
    has_one :bank_account_balance, class_name: "TudlaAccounting::BankAccountBalance", dependent: :destroy

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

    private

    def validate_parent
      return if parent_id.nil?

      errors.add(:base, "Attributes are not compatible with parent") if
        category != parent.category
    end
  end
end
