# frozen_string_literal: true

module TudlaAccounting
  # A tax that lines can be taxed under (GST on sales, VAT on purchases, GST-free...).
  # A sales code's tax is collected and owed to the tax authority; a purchases code's is
  # paid and claimed back. The tax is posted to the code's account, on the same side as
  # the line it is on; a zero-rate code needs no account, but its lines are still reported.
  class TaxCode < ApplicationRecord
    belongs_to :organization, polymorphic: true
    belongs_to :account, class_name: "TudlaAccounting::Account", optional: true
    has_many :details, class_name: "TudlaAccounting::Detail", dependent: :restrict_with_error

    enum :kind, { sales: 0, purchases: 1 }

    validates :code, :name, :kind, presence: true
    validates :code, uniqueness: { scope: %i[organization_type organization_id] }
    validates :rate, numericality: { greater_than_or_equal_to: 0, less_than: 10 }
    validate :account_for_tax
    validate :kind_unchanged_once_used, on: :update
    before_destroy :ensure_unused, prepend: true

    after_create { audit("tax_code.created") }
    after_update { audit("tax_code.updated", changes: saved_changes.except("created_at", "updated_at")) if saved_changes.except("created_at", "updated_at").any? }
    after_destroy { audit("tax_code.deleted") }

    scope :active, -> { where(active: true) }

    # The rate as a percentage, for forms and labels, in the organization's number format:
    # "10" for 0.1, "12.5" (or "12,5") for 0.125.
    def rate_percent
      rate && AmountParser.number_text(rate * 100, format: number_format)
    end

    def rate_percent=(percent)
      self.rate = AmountParser.decimal(percent, format: number_format)&./(100)
    rescue ArgumentError
      self.rate = nil
      @unreadable_rate = percent
    end

    # The tax on amount_cents at this code's rate: on top of it, or (inclusive) the part of
    # it that is tax. Rounded to the cent the configured way.
    def tax_cents(amount_cents, inclusive: false)
      amount = BigDecimal(amount_cents)
      tax = inclusive ? amount * rate / (1 + rate) : amount * rate
      tax.round(0, TudlaAccounting.configuration.rounding).to_i
    end

    def number_format = organization ? NumberFormat.for(organization) : AmountParser::POINT

    # "GST (10%)"
    def label
      "#{code} (#{rate_percent}%)"
    end

    def used?
      details.exists?
    end

    private

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end

    def kind_unchanged_once_used
      errors.add(:kind, "can't change once lines are taxed under it; add a new code instead") if kind_changed? && used?
    end

    # Taxed lines keep their code; recurring entries, bank rules, tax returns, contacts and
    # documents refer to it.
    def ensure_unused
      problem = if used? then "Lines are taxed under #{code}; make it inactive instead"
      elsif RecurringEntryLine.where(tax_code_id: id).exists? || BankRule.where(tax_code_id: id).exists? || TaxReturnBoxPart.where(tax_code_id: id).exists? ||
            Contact.where(default_tax_code_id: id).exists? || DocumentLine.where(tax_code_id: id).exists?
        "Recurring entries, bank rules, tax returns, contacts or invoices and bills use #{code}; change them first"
      end
      return unless problem

      errors.add(:base, problem)
      throw :abort
    end

    def account_for_tax
      errors.add(:rate, "#{@unreadable_rate} isn't a number") if @unreadable_rate
      if rate.to_d.positive? && account.nil?
        errors.add(:account, "is needed for a code with a rate")
      elsif account && account.organization != organization
        errors.add(:account, "must belong to the same organization")
      elsif account && !account.active? && active? && (will_save_change_to_account_id? || will_save_change_to_active?)
        errors.add(:account, "is inactive")
      end
    end
  end
end
