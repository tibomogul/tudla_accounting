# frozen_string_literal: true

module TudlaAccounting
  # A customer or supplier (kind customer, supplier or both): who documents are to or
  # from, and the party their receivables and payables are owed by or to (see
  # PartyStatement). payment_terms_days sets when its documents fall due; the default
  # account and tax code start its documents' lines. An inactive contact keeps its
  # history but isn't offered for new documents; one that is owed or owes anything, or
  # ever was, can't be deleted.
  class Contact < ApplicationRecord
    KINDS = { "customer" => "Customer", "supplier" => "Supplier", "both" => "Customer and supplier" }.freeze

    belongs_to :organization, polymorphic: true
    belongs_to :default_account, class_name: "TudlaAccounting::Account", optional: true
    belongs_to :default_tax_code, class_name: "TudlaAccounting::TaxCode", optional: true
    has_many :documents, class_name: "TudlaAccounting::Document"

    normalizes :name, with: ->(name) { name.squish }
    normalizes :email, :phone, :tax_number, with: ->(text) { text.strip.presence }
    normalizes :address, :notes, with: ->(text) { text.strip.presence }

    validates :name, presence: true
    validates :kind, inclusion: { in: KINDS.keys }
    validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true
    validates :payment_terms_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validate :defaults_fit

    before_destroy :ensure_no_history
    after_create { audit("contact.created") }
    after_update { audit("contact.updated", changes: saved_changes.except("created_at", "updated_at")) if saved_changes.except("created_at", "updated_at").any? }
    after_destroy { audit("contact.deleted") }

    scope :active, -> { where(active: true) }
    scope :customers, -> { where(kind: %w[customer both]) }
    scope :suppliers, -> { where(kind: %w[supplier both]) }

    # Contacts whose name, email or tax number contains the text, in any case.
    def self.search(text)
      pattern = "%#{sanitize_sql_like(text.to_s.strip)}%"
      where("name ILIKE :pattern OR email ILIKE :pattern OR tax_number ILIKE :pattern", pattern: pattern)
    end

    def customer? = kind.in?(%w[customer both])
    def supplier? = kind.in?(%w[supplier both])

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
    end

    def ensure_no_history
      return if deletable?

      errors.add(:base, "#{name} has invoices, bills or payments; make it inactive instead")
      throw :abort
    end

    def audit(action, **details)
      AuditEvent.record!(action, organization: organization, subject: self, details: details)
    end
  end
end
