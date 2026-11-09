# frozen_string_literal: true

module TudlaAccounting
  # A customer or supplier (kind customer, supplier or both): who documents are to or
  # from, and the party their receivables and payables are owed by or to (see
  # PartyStatement). payment_terms_days sets when its documents fall due; currency (nil
  # for the organization's own) is the one its new documents and payments start in; the
  # default account, tax code and withholding code start its documents' lines. An inactive contact keeps its
  # history but isn't offered for new documents; one that is owed or owes anything, or
  # ever was, can't be deleted.
  class Contact < ApplicationRecord
    KINDS = { "customer" => "Customer", "supplier" => "Supplier", "both" => "Customer and supplier" }.freeze
    POSTAL_CODE_LENGTH = 12 # the longest that fits the box on a printed form
    # Why nothing is withheld from what is paid to a supplier under its code withheld on
    # payment: the ATO's exceptions to no-ABN withholding, each normally backed by the
    # supplier's statement (its date in withholding_statement_on). See PaymentWithholding.
    WITHHOLDING_EXEMPTIONS = {
      "not_in_business" => "Not a business transaction: an individual not in business, or a private, domestic or hobby supply",
      "exempt_income" => "The whole payment is exempt income for them",
      "no_enterprise" => "Not carrying on an enterprise",
      "under_18" => "An individual under 18 paid $350 or less a week",
      "through_agent" => "Supplied through an agent who quoted their ABN",
      "input_taxed" => "The supplies are wholly input taxed"
    }.freeze

    include OrganizationOwned
    belongs_to :default_account, class_name: "TudlaAccounting::Account", optional: true
    belongs_to :default_tax_code, class_name: "TudlaAccounting::TaxCode", optional: true
    belongs_to :default_withholding_code, class_name: "TudlaAccounting::WithholdingCode", optional: true
    has_many :documents, class_name: "TudlaAccounting::Document"

    # A date: on save, its payments made since then (paid and refunds from it) take its
    # taxable_payments mark too. Without it, the mark applies to payments made from now on.
    attribute :taxable_payments_from, :date

    normalizes :name, with: ->(name) { name.squish }
    normalizes :email, :phone, :postal_code, :tax_number, with: ->(text) { text.strip.presence }
    normalizes :address, :notes, with: ->(text) { text.strip.presence }
    normalizes :currency, with: ->(currency) { currency.strip.upcase.presence }
    normalizes :withholding_exemption, with: ->(exemption) { exemption.strip.presence }
    before_validation { self.currency = nil if self[:currency] == organization&.currency }

    validates :name, presence: true
    validates :kind, inclusion: { in: KINDS.keys }
    validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true
    validates :postal_code, length: { maximum: POSTAL_CODE_LENGTH }
    validates :payment_terms_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validates :withholding_exemption, inclusion: { in: WITHHOLDING_EXEMPTIONS.keys }, allow_nil: true
    validate :defaults_fit
    validate { errors.add(:currency, "is not a known currency code") if foreign? && !Money::Currency.find(self[:currency]) }

    before_destroy :ensure_no_history
    after_create { audit("contact.created") }
    after_update { audit("contact.updated", changes: saved_changes.except("created_at", "updated_at")) if saved_changes.except("created_at", "updated_at").any? }
    after_destroy { audit("contact.deleted") }
    after_save :mark_payments_since, if: :taxable_payments_from

    scope :active, -> { where(active: true) }
    scope :customers, -> { where(kind: %w[customer both]) }
    scope :suppliers, -> { where(kind: %w[supplier both]) }

    # Contacts whose name, email or tax number contains the text, in any case.
    def self.search(text)
      pattern = "%#{sanitize_sql_like(text.to_s.strip)}%"
      where("name ILIKE :pattern OR email ILIKE :pattern OR tax_number ILIKE :pattern", pattern: pattern)
    end

    # The currency its new documents and payments start in: the organization's unless
    # another is set.
    def currency = self[:currency] || organization&.currency || TudlaAccounting.configuration.base_currency
    def foreign? = self[:currency].present?

    # The address as it prints on documents, with the postal code on its own line.
    def full_address = [ address, postal_code ].compact.join("\n").presence

    def customer? = kind.in?(%w[customer both])
    def supplier? = kind.in?(%w[supplier both])

    # The code withheld from what is paid to this supplier (its default withholding code,
    # when that is active and withheld on payment), or nil.
    def payment_withholding_code
      code = default_withholding_code
      code if code&.active? && code.on_payment?
    end

    # Its exemption from withholding, as a payment made without the tax records it: "Not
    # carrying on an enterprise (their statement of 3 Mar 2026)", or nil.
    def withholding_exemption_reason
      label = WITHHOLDING_EXEMPTIONS[withholding_exemption] or return
      withholding_statement_on ? "#{label} (their statement of #{withholding_statement_on.strftime('%-d %b %Y')})" : label
    end

    # The receivable and payable types it is a party to: as a customer, a supplier, or both.
    def party_types
      [ (:receivable if customer?), (:payable if supplier?) ].compact
    end

    def kind_label
      KINDS.fetch(kind)
    end

    # When a document dated date falls due, by the payment terms; nil without terms.
    def due_on(date)
      date + payment_terms_days if payment_terms_days
    end

    def deletable?
      !CarryingAmount.where(related_party: self).exists? && !Document.where(contact: self).exists?
    end

    private

    def defaults_fit
      errors.add(:default_account, "must belong to the same organization") if default_account && default_account.organization != organization
      errors.add(:default_tax_code, "must belong to the same organization") if default_tax_code && default_tax_code.organization != organization
      errors.add(:default_withholding_code, "must belong to the same organization") if default_withholding_code && default_withholding_code.organization != organization
    end

    def ensure_no_history
      return if deletable?

      errors.add(:base, "#{name} has invoices, bills or payments; make it inactive instead")
      throw :abort
    end

    # Marks (or unmarks) its payments since taxable_payments_from as its own mark is now.
    def mark_payments_since
      payments = Payment.where(organization: organization, contact: self, kind: Payment::TAXABLE_KINDS, paid_on: taxable_payments_from..)
                        .where.not(taxable_payment: taxable_payments?)
      changed = payments.update_all(taxable_payment: taxable_payments?, updated_at: Time.current)
      audit("contact.taxable_payments_marked", taxable_payments: taxable_payments?, from: taxable_payments_from.iso8601, payments: changed) if changed.positive?
      self.taxable_payments_from = nil
    end

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end
  end
end
