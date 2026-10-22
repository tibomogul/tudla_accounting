# frozen_string_literal: true

module TudlaAccounting
  # A line of a RecurringInvoice, as an invoice's line (DocumentLine) is: a description,
  # quantity and unit price, the account and tax code, and dimension values. Whether they
  # suit an invoice is checked on the invoice the template would make.
  class RecurringInvoiceLine < ApplicationRecord
    belongs_to :recurring_invoice, class_name: "TudlaAccounting::RecurringInvoice", inverse_of: :lines
    belongs_to :account, class_name: "TudlaAccounting::Account"
    belongs_to :tax_code, class_name: "TudlaAccounting::TaxCode", optional: true

    normalizes :description, with: ->(description) { description.squish }

    validates :description, presence: true, length: { maximum: 255 }
    validates :quantity, numericality: { greater_than_or_equal_to: 0, less_than: 10**11 }
    validates :unit_price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    def dimension_values
      DimensionValue.where(id: dimension_value_ids).includes(:dimension)
    end

    def dimension_value_for(dimension)
      dimension_values.find { |value| value.dimension_id == dimension.id }
    end

    # Quantity times unit price, rounded as an invoice's line is.
    def amount_cents
      (quantity.to_d * unit_price_cents.to_i).round(0, TudlaAccounting.configuration.rounding).to_i
    end

    def unit_price = money(unit_price_cents)
    def amount = money(amount_cents)

    def document_line_attributes
      { description: description, quantity: quantity, unit_price_cents: unit_price_cents, account: account, tax_code: tax_code, dimension_value_ids: dimension_value_ids }
    end

    private

    def money(cents) = Money.new(cents.to_i, recurring_invoice&.organization&.currency || TudlaAccounting.configuration.base_currency)
  end
end
