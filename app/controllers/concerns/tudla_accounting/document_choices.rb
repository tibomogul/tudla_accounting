module TudlaAccounting
  # The contacts, accounts and tax codes an invoice or bill's form offers (a recurring
  # invoice's too): those in use, and what is still active. The record answers sales?,
  # contact_id and lines.
  module DocumentChoices
    extend ActiveSupport::Concern

    included do
      helper_method :document_accounts, :document_tax_codes, :document_contacts
    end

    private

    # The side's active customers or suppliers, and the one it has.
    def document_contacts(record)
      contacts = organization_scope(Contact).order(Arel.sql("LOWER(name)"))
      contacts = record.sales? ? contacts.customers : contacts.suppliers
      contacts.active.or(contacts.where(id: record.contact_id))
    end

    # Active accounts other than receivables and payables, and any the lines have already.
    def document_accounts(record)
      used = record.lines.filter_map(&:account_id)
      accounts = organization_scope(Account).where(role: nil).or(organization_scope(Account).where.not(role: %w[receivable payable]))
      accounts.active.or(organization_scope(Account).where(id: used)).order(:code)
    end

    # The side's active tax codes, and any the lines have already.
    def document_tax_codes(record)
      used = record.lines.filter_map(&:tax_code_id)
      codes = organization_scope(TaxCode).where(kind: record.sales? ? :sales : :purchases)
      codes.active.or(codes.where(id: used)).order(:code)
    end
  end
end
