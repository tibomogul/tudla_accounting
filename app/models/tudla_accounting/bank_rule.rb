# frozen_string_literal: true

module TudlaAccounting
  # How to record a bank statement line the books don't have yet: a line whose description
  # contains description_contains (ignoring case) and, optionally, that is money in or out
  # (direction) within an amount range (on its size), on one bank account (account) or
  # any, is recorded against counter_account, with an optional tax code (the line's amount
  # includes the tax) and dimension values, under particulars or the line's description.
  #
  # Rules apply in order of position, then id: the first that matches a line is its rule.
  # They only suggest: BankReconciler#record_by_rules! records the lines someone chooses
  # to (see BankReconciler#rule_suggestions).
  class BankRule < ApplicationRecord
    DIRECTIONS = %w[in out].freeze

    belongs_to :organization, polymorphic: true
    belongs_to :account, class_name: "TudlaAccounting::Account", optional: true
    belongs_to :counter_account, class_name: "TudlaAccounting::Account"
    belongs_to :tax_code, class_name: "TudlaAccounting::TaxCode", optional: true

    normalizes :description_contains, with: ->(text) { text.strip }
    normalizes :particulars, with: ->(text) { text.strip.presence }
    normalizes :direction, with: ->(direction) { direction.presence }

    validates :name, :description_contains, presence: true
    validates :direction, inclusion: { in: DIRECTIONS }, allow_nil: true
    validates :amount_min_cents, :amount_max_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validate :amounts_in_order
    validate :accounts_fit
    validate :tax_and_dimensions_fit

    after_create { audit("bank_rule.created") }
    after_update { audit("bank_rule.updated", changes: saved_changes.except("created_at", "updated_at")) if saved_changes.except("created_at", "updated_at").any? }
    after_destroy { audit("bank_rule.deleted") }

    scope :active, -> { where(active: true) }
    scope :in_order, -> { order(:position, :id) }

    def matches?(line)
      return false unless active? && (account_id.nil? || account_id == line.account_id)
      return false unless line.description.to_s.downcase.include?(description_contains.downcase)
      return false if direction == "in" && !line.amount_cents.positive?
      return false if direction == "out" && !line.amount_cents.negative?

      size = line.amount_cents.abs
      (amount_min_cents.nil? || size >= amount_min_cents) && (amount_max_cents.nil? || size <= amount_max_cents)
    end

    def dimension_values
      DimensionValue.where(id: dimension_value_ids).includes(:dimension)
    end

    # "6200 - Software, GST" and the like, for the banking page.
    def outcome_label
      [ counter_account.code_with_name, tax_code&.code, *dimension_values.map(&:name) ].compact.join(", ")
    end

    private

    def amounts_in_order
      errors.add(:amount_max_cents, "must be at least the smallest amount") if amount_min_cents && amount_max_cents && amount_max_cents < amount_min_cents
    end

    def accounts_fit
      errors.add(:account, "must belong to the same organization") if account && account.organization != organization
      return unless counter_account

      if counter_account.organization != organization then errors.add(:counter_account, "must belong to the same organization")
      elsif !counter_account.active? && (new_record? || will_save_change_to_counter_account_id?) then errors.add(:counter_account, "is inactive")
      elsif account && counter_account == account then errors.add(:counter_account, "must be another account than the bank account")
      end
    end

    def tax_and_dimensions_fit
      errors.add(:tax_code, "must belong to the same organization") if tax_code && tax_code.organization != organization
      values = dimension_values.to_a
      errors.add(:dimension_value_ids, "must belong to the same organization") if values.any? { |value| value.dimension.organization != organization }
      errors.add(:dimension_value_ids, "can have one value of each dimension") if values.map(&:dimension_id).uniq.size < values.size
    end

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end
  end
end
