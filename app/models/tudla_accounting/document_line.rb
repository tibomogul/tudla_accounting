# frozen_string_literal: true

module TudlaAccounting
  # A line of a Document: what was sold or bought (description), how many and at what unit
  # price, the income, expense or other account it goes to, and an optional tax code of
  # the document's side (a sales code on sales, a purchases code on bills). amount_cents is
  # quantity times unit price, rounded to the cent; tax_cents the tax on it, added or
  # (when the document's amounts include the tax) split out, rounded per line as an
  # entry's tax is. dimension_value_ids tag it (one value per dimension) as an entry's line
  # is tagged; approving the document tags its posting.
  class DocumentLine < ApplicationRecord
    belongs_to :document, class_name: "TudlaAccounting::Document", inverse_of: :lines
    belongs_to :account, class_name: "TudlaAccounting::Account"
    belongs_to :tax_code, class_name: "TudlaAccounting::TaxCode", optional: true

    normalizes :description, with: ->(description) { description.squish }

    validates :description, presence: true, length: { maximum: 255 }
    validates :quantity, numericality: { greater_than_or_equal_to: 0, less_than: 10**11 }
    validates :unit_price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :fits_the_document
    validate :document_is_a_draft

    # Sets amount_cents and tax_cents, with the document's amounts including the tax or not.
    def work_out(inclusive)
      self.amount_cents = (quantity.to_d * unit_price_cents.to_i).round(0, TudlaAccounting.configuration.rounding).to_i
      self.tax_cents = tax_code ? tax_code.tax_cents(amount_cents, inclusive: inclusive) : 0
    end

    # The amount before tax.
    def net_cents
      document&.tax_inclusive? ? amount_cents - tax_cents.to_i : amount_cents
    end

    def dimension_values
      DimensionValue.where(id: dimension_value_ids).includes(:dimension)
    end

    def dimension_value_for(dimension)
      dimension_values.find { |value| value.dimension_id == dimension.id }
    end

    def unit_price = money(unit_price_cents)
    def amount = money(amount_cents)

    private

    def money(cents) = Money.new(cents.to_i, document&.organization&.currency || TudlaAccounting.configuration.base_currency)

    def document_is_a_draft
      errors.add(:base, "An approved document's lines can't be changed") if document && document.status_was != "draft" && document.persisted? && has_changes_to_save?
    end

    def fits_the_document
      organization = document&.organization
      return unless organization

      errors.add(:account, "must belong to the same organization") if account && account.organization != organization
      errors.add(:account, "is inactive") if account && !account.active? && will_save_change_to_account_id?
      if account&.role.in?(%w[receivable payable])
        errors.add(:account, "can't be the receivables or payables account; the document posts its total there")
      end
      dimensions_fit(organization)
      return unless tax_code

      errors.add(:tax_code, "must belong to the same organization") if tax_code.organization != organization
      wanted = document.sales? ? "sales" : "purchases"
      errors.add(:tax_code, "must be a #{wanted} code") if Document::KINDS.key?(document.kind) && tax_code.kind != wanted
    end

    def dimensions_fit(organization)
      return if dimension_value_ids.empty?

      values = dimension_values.to_a
      errors.add(:dimension_value_ids, "must belong to the same organization") if values.size < dimension_value_ids.uniq.size || values.any? { |value| value.dimension.organization != organization }
      errors.add(:dimension_value_ids, "can have one value of each dimension") if values.map(&:dimension_id).uniq.size < values.size
    end
  end
end
