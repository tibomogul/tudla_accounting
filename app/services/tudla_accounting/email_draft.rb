# frozen_string_literal: true

module TudlaAccounting
  # The email something starts with, from the document_email_templates setting: who it
  # goes to (the contact's email), its subject line and message, the placeholders filled
  # in, and for a statement the details it is made from.
  #
  #   EmailDraft.for_document(invoice) # => { kind: "document", to:, subject_line:, message: }
  #   EmailDraft.for_statement(statement, open_items: false)
  #   EmailDraft.for_payment(payment)  # a receipt, or a payment notice
  module EmailDraft
    module_function

    def for_document(document)
      draft("document", document.kind == "sales_credit" ? "credit_note" : "invoice", document.organization, document.contact, document_values(document))
    end

    # A reminder of an overdue invoice, for the reminder day it is (days after the due
    # date; nil for one sent by hand before any of them).
    def for_reminder(invoice, days:)
      draft("reminder", "reminder", invoice.organization, invoice.contact, document_values(invoice)).merge(stage: days)
    end

    def document_values(document)
      books = document.organization
      { number: document.number_label, kind: document.kind_label, total: MoneyFormatter.labelled(document.total, books), amount_due: MoneyFormatter.labelled(document.amount_due, books),
        issued_on: day(document.issued_on), due_on: day(document.due_on) }
    end

    # A statement's (a PartyStatement), to its customer or supplier: their contact, or a host
    # app's record with an email.
    def for_statement(statement, open_items:)
      values = { from: day(statement.from), thru: day(statement.thru), balance: MoneyFormatter.labelled(statement.closing, statement.organization) }
      details = { "type" => statement.type.to_s, "from" => statement.from.iso8601, "thru" => statement.thru.iso8601, "open_items" => open_items }
      draft("statement", "statement", statement.organization, statement.party, values).merge(details: details)
    end

    def for_payment(payment)
      kind = payment.received? ? "receipt" : "payment_notice"
      draft(kind, kind, payment.organization, payment.contact, amount: MoneyFormatter.labelled(payment.amount, payment.organization), paid_on: day(payment.paid_on), reference: payment.reference)
    end

    def draft(kind, template, organization, party, values)
      text = TudlaAccounting.configuration.document_email_templates.fetch(template)
      values = values.merge(organization: organization_name(organization), contact: PartyStatement.party_name(party))
      { kind: kind, to: (party.email if party.respond_to?(:email)), subject_line: fill(text[:subject], values), message: fill(text[:body], values) }
    end

    # The text with each %{placeholder} it knows replaced; others are left as they are.
    def fill(text, values)
      text.to_s.gsub(/%\{(\w+)\}/) { values.key?(::Regexp.last_match(1).to_sym) ? values[::Regexp.last_match(1).to_sym].to_s : ::Regexp.last_match(0) }
    end

    def organization_name(organization)
      organization.respond_to?(:name) && organization.name.present? ? organization.name : TudlaAccounting.organization_label(organization)
    end

    def day(date) = date&.strftime("%-d %b %Y")
  end
end
