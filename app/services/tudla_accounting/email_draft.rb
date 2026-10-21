# frozen_string_literal: true

module TudlaAccounting
  # The email a document starts with, from the document_email_templates setting: who it
  # goes to (the contact's email), its subject line and message, the placeholders filled in.
  #
  #   EmailDraft.for_document(invoice) # => { kind: "document", to:, subject_line:, message: }
  module EmailDraft
    module_function

    def for_document(document)
      template = document.kind == "sales_credit" ? "credit_note" : "invoice"
      values = { number: document.number_label, kind: document.kind_label, total: document.total.format, amount_due: document.amount_due.format,
                 issued_on: day(document.issued_on), due_on: day(document.due_on) }
      draft("document", template, document.organization, document.contact, values)
    end

    def draft(kind, template, organization, contact, values)
      text = TudlaAccounting.configuration.document_email_templates.fetch(template)
      values = values.merge(organization: organization_name(organization), contact: contact.name)
      { kind: kind, to: contact.email, subject_line: fill(text[:subject], values), message: fill(text[:body], values) }
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
