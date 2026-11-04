# frozen_string_literal: true

module TudlaAccounting
  # A tax that lines can be taxed under (GST on sales, VAT on purchases, GST-free...).
  # A sales code's tax is collected and owed to the tax authority; a purchases code's is
  # paid and claimed back. The tax is posted to the code's account, on the same side as
  # the line it is on; a zero-rate code needs no account, but its lines are still reported.
  #
  # treatment tells apart the codes without tax: standard (taxed at the rate, which may be
  # 0), zero_rated (taxable at 0%, such as exports) and exempt (outside the tax); the last
  # two have no rate. Returns and the sales journal report them apart.
  #
  # purchase_type says what a taxed purchases code's lines are bought as, for lists that
  # split them (the Philippines' summary list of purchases). It can be left unset, and only
  # such a code has one. It can change after use: it classifies lines, and posts nothing.
  class TaxCode < ApplicationRecord
    include PercentRate

    belongs_to :organization, polymorphic: true
    belongs_to :account, class_name: "TudlaAccounting::Account", optional: true
    has_many :details, class_name: "TudlaAccounting::Detail", dependent: :restrict_with_error

    enum :kind, { sales: 0, purchases: 1 }
    enum :treatment, { standard: 0, zero_rated: 1, exempt: 2 }, validate: true

    enum :purchase_type, { services: 0, capital_goods: 1, other_goods: 2 }, prefix: :bought_as, validate: { allow_nil: true }

    TREATMENTS = { "standard" => "Taxed at the rate", "zero_rated" => "Zero-rated (0%, e.g. exports)", "exempt" => "Exempt (outside the tax)" }.freeze

    PURCHASE_TYPES = { "services" => "Services", "capital_goods" => "Capital goods", "other_goods" => "Other goods" }.freeze

    before_validation { self.purchase_type = nil unless purchases? && standard? }
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

    # The tax on amount_cents at this code's rate: on top of it, or (inclusive) the part of
    # it that is tax. Rounded to the cent the configured way.
    def tax_cents(amount_cents, inclusive: false)
      amount = BigDecimal(amount_cents)
      tax = inclusive ? amount * rate / (1 + rate) : amount * rate
      tax.round(0, TudlaAccounting.configuration.rounding).to_i
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
      errors.add(:rate, "must be 0 for #{zero_rated? ? 'a zero-rated' : 'an exempt'} code") if !standard? && rate.to_d.nonzero?
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
