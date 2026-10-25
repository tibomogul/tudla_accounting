# frozen_string_literal: true

module TudlaAccounting
  # A line of a RecurringEntry: a debit or credit of an amount (in the organization's
  # currency) to an account, with an optional description, tax code and dimension values,
  # as an entry's line has.
  class RecurringEntryLine < ApplicationRecord
    belongs_to :recurring_entry, class_name: "TudlaAccounting::RecurringEntry", inverse_of: :lines
    belongs_to :account, class_name: "TudlaAccounting::Account"
    belongs_to :tax_code, class_name: "TudlaAccounting::TaxCode", optional: true

    enum :tally, { debit: 0, credit: 1 }

    normalizes :description, with: ->(description) { description.strip.presence }

    validates :tally, presence: true
    validates :amount_cents, numericality: { only_integer: true, greater_than: 0, message: "must be more than zero" }
    validates :description, length: { maximum: 255 }
    validate :same_organization

    def dimension_values
      DimensionValue.where(id: dimension_value_ids).includes(:dimension)
    end

    # As an entry line's, for the line editor.
    def amount
      Money.new(amount_cents.to_i, recurring_entry&.organization&.currency || TudlaAccounting.configuration.base_currency)
    end

    def dimension_value_for(dimension)
      dimension_values.find { |value| value.dimension_id == dimension.id }
    end

    # The line for Entry.create_from_ruby_hash: the account's code and the amount signed
    # the natural way for it (positive increases it).
    def detail_hash(currency)
      increases = debit? == account.debit_balance?
      amount = AmountParser.text(Money.new(amount_cents, currency))
      { account_code: account.code, amount: "#{currency} #{'-' unless increases}#{amount}", description: description,
        tax_code: tax_code&.code, dimensions: dimension_values.to_h { |value| [ value.dimension.code, value.code ] }.presence }.compact
    end

    private

    def same_organization
      organization = recurring_entry&.organization
      return unless organization

      errors.add(:account, "must belong to the same organization") if account && account.organization != organization
      errors.add(:tax_code, "must belong to the same organization") if tax_code && tax_code.organization != organization
      values = dimension_values.to_a
      errors.add(:dimension_value_ids, "must belong to the same organization") if values.any? { |value| value.dimension.organization != organization }
      errors.add(:dimension_value_ids, "can have one value of each dimension") if values.map(&:dimension_id).uniq.size < values.size
    end
  end
end
