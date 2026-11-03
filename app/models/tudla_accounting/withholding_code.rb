# frozen_string_literal: true

module TudlaAccounting
  # A tax withheld from a payment: its code (the BIR's ATC, for the Philippines), what it is
  # for and its rate. One code serves both directions, by which account it has: the payable
  # account (a liability) for tax withheld from suppliers, owed to the tax authority, and
  # the creditable account (an asset) for tax customers withhold, claimed against income
  # tax. WithholdingCodeTemplates has a starter list.
  class WithholdingCode < ApplicationRecord
    include PercentRate

    belongs_to :organization, polymorphic: true
    belongs_to :payable_account, class_name: "TudlaAccounting::Account", optional: true
    belongs_to :creditable_account, class_name: "TudlaAccounting::Account", optional: true

    normalizes :code, with: ->(code) { code.strip.upcase }
    normalizes :name, with: ->(name) { name.squish }

    validates :code, :name, presence: true
    validates :code, uniqueness: { scope: %i[organization_type organization_id] }
    validates :rate, numericality: { greater_than: 0, less_than: 1 }
    validate :accounts_fit
    validate :unchanged_once_posted, on: :update
    before_destroy :ensure_unused, prepend: true

    after_create { audit("withholding_code.created") }
    after_update { audit("withholding_code.updated", changes: saved_changes.except("created_at", "updated_at")) if saved_changes.except("created_at", "updated_at").any? }
    after_destroy { audit("withholding_code.deleted") }

    scope :active, -> { where(active: true) }

    # The tax on base_cents at this code's rate, rounded to the cent the configured way.
    def withheld_cents(base_cents)
      (BigDecimal(base_cents) * rate).round(0, TudlaAccounting.configuration.rounding).to_i
    end

    def used? = posted? || Contact.where(default_withholding_code_id: id).exists? || DocumentLine.where(withholding_code_id: id).exists?
    def posted? = WithheldTax.where(withholding_code_id: id).exists?

    private

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end

    def ensure_unused
      return unless used?

      errors.add(:base, "Bills, payments or contacts use #{code}; make it inactive instead")
      throw :abort
    end

    # Reports read the rate and the accounts from the code, so what has been posted under
    # it fixes them.
    def unchanged_once_posted
      fields = %w[code rate payable_account_id creditable_account_id].select { |field| will_save_change_to_attribute?(field) }
      errors.add(:base, "Tax has been posted under #{code_was}, so its #{fields.map { |field| field.delete_suffix('_id').humanize(capitalize: false) }.to_sentence} can't change; add a new code instead") if fields.any? && posted?
    end

    def accounts_fit
      errors.add(:base, "Choose an account for tax withheld from suppliers, for tax customers withhold, or both") unless payable_account || creditable_account
      account_fits(:payable_account, Account::CATEGORY_LIABILITY, "a liability")
      account_fits(:creditable_account, Account::CATEGORY_ASSET, "an asset")
    end

    def account_fits(field, category, wanted)
      account = public_send(field)
      return unless account

      if account.organization != organization then errors.add(field, "must belong to the same organization")
      elsif account.category != category then errors.add(field, "must be #{wanted} account")
      elsif account.path.any? { |held| held.role.in?(%w[receivable payable]) } then errors.add(field, "can't be the receivables or payables account")
      elsif will_save_change_to_attribute?("#{field}_id")
        problem = account.active? ? account.posting_blocker : "is inactive"
        errors.add(field, problem) if problem
      end
    end
  end
end
