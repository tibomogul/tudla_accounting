module TudlaAccounting
  module Api
    # How the JSON API shows the books' records. Amounts are decimal strings in the
    # organization's currency ("1234.50", negative with a minus sign) beside a "currency";
    # dates are ISO 8601 ("2026-03-31") and times ISO 8601 with their offset. Accounts, tax
    # codes and dimension values are named by their codes.
    module Representation
      private

      def amount(money) = money && Reports::Table.csv_cell(money)
      def time(value) = value&.iso8601
      # A date, or the day a time falls on in the books' time zone.
      def date(value)
        value = value.in_time_zone(TudlaAccounting.configuration.time_zone) if value && !value.is_a?(Date)
        value&.to_date&.iso8601
      end

      def organization_json(organization)
        { id: organization.id, name: (organization.name if organization.respond_to?(:name)), currency: organization.currency }
      end

      def account_json(account)
        { id: account.id, code: account.code, name: account.name, category: account.category, role: account.role, currency: account.currency,
          parent_code: account.parent&.code, contra_account_code: account.contra_account&.code, cash_flow_activity: account.cash_flow_activity,
          active: account.active?, created_at: time(account.created_at), updated_at: time(account.updated_at) }
      end

      def entry_json(entry)
        source = entry.source_type && { type: entry.source_type.delete_prefix("TudlaAccounting::").underscore, id: entry.source_id }
        { id: entry.id, number: entry.number_label, status: entry.posted? ? "posted" : "draft", particulars: entry.particulars, reference: entry.reference,
          transacted_at: time(entry.transacted_at), posted_at: time(entry.posted_at), reverse_on: date(entry.reverse_on),
          related_entry_id: (entry.related_id if entry.related_type == Entry.name), source: source, idempotency_key: entry.idempotency_key,
          currency: entry.details.first&.currency, lines: entry.details.map { |detail| line_json(detail) }, attachments: attachments_json(entry),
          created_at: time(entry.created_at), updated_at: time(entry.updated_at) }
      end

      def line_json(detail)
        { account_code: detail.account.code, debit: (amount(detail.amount) if detail.debit?), credit: (amount(detail.amount) if detail.credit?),
          description: detail.description, tax_code: detail.tax_code&.code, tax_role: detail.tax_role,
          foreign: detail.foreign_exchange && { currency: detail.foreign_exchange.other_currency, amount: amount(Money.new(detail.foreign_exchange.other_currency_cents, detail.foreign_exchange.other_currency)),
                                                rate: detail.foreign_exchange.rate.to_s },
          dimensions: detail.tags.to_h { |tag| [ tag.dimension.code, tag.dimension_value.code ] } }
      end

      def contact_json(contact)
        contact.slice(:id, :name, :kind, :email, :phone, :address, :tax_number, :payment_terms_days, :notes)
          .merge(default_account_code: contact.default_account&.code, default_tax_code: contact.default_tax_code&.code, active: contact.active?,
                 created_at: time(contact.created_at), updated_at: time(contact.updated_at))
      end

      def document_json(document)
        { id: document.id, kind: document.kind, status: document.status, payment_status: document.payment_status, number: document.number_label,
          contact: { id: document.contact_id, name: document.contact.name }, reference: document.reference,
          issued_on: date(document.issued_on), due_on: date(document.due_on), tax_inclusive: document.tax_inclusive?, currency: document.currency,
          exchange_rate: document.exchange_rate&.to_s("F"), amount_due_in_base: (amount(document.amount_due_in_base) if document.foreign?),
          subtotal: amount(document.subtotal), tax: amount(document.tax), total: amount(document.total), amount_due: amount(document.amount_due),
          credited_document_id: document.credited_document_id, entry_id: document.entry_id, notes: document.notes,
          lines: document_lines_json(document),
          attachments: attachments_json(document),
          approved_at: time(document.approved_at), voided_on: date(document.voided_on), void_reason: document.void_reason,
          created_at: time(document.created_at), updated_at: time(document.updated_at) }
      end

      def document_lines_json(document)
        values = DimensionValue.where(id: document.lines.flat_map(&:dimension_value_ids)).includes(:dimension).index_by(&:id)
        document.lines.map do |line|
          { description: line.description, quantity: line.quantity.to_s("F"), unit_price: amount(line.unit_price), amount: amount(line.amount),
            account_code: line.account.code, tax_code: line.tax_code&.code, tax: amount(Money.new(line.tax_cents, document.currency)),
            dimensions: line.dimension_value_ids.filter_map { |id| values[id] }.to_h { |value| [ value.dimension.code, value.code ] } }
        end
      end

      def payment_json(payment)
        { id: payment.id, kind: payment.kind, status: payment.status, contact: { id: payment.contact_id, name: payment.contact.name },
          account_code: payment.account.code, paid_on: date(payment.paid_on), currency: payment.organization.currency,
          amount: amount(payment.amount), unapplied: amount(payment.unapplied), reference: payment.reference, notes: payment.notes, entry_id: payment.entry_id,
          applied: payment.applications.map do |target, applied, allocation|
            { document_id: (target.id if target.is_a?(Document)), number: (target.number_label if target.is_a?(Document)), payment_id: (target.id if target.is_a?(Payment)),
              entry_id: (target.is_a?(Entry) ? target.id : target.entry_id), amount: amount(applied), applied_at: time(allocation.allocated_at), active: allocation.active? }
          end,
          refund_of: payment.refund_of&.then { |credit| credit.is_a?(Payment) ? { payment_id: credit.id } : { document_id: credit.id } },
          voided_on: date(payment.voided_on), void_reason: payment.void_reason, created_at: time(payment.created_at), updated_at: time(payment.updated_at) }
      end

      # Its files (none without Active Storage), each fetched from its attachments endpoint.
      def attachments_json(record)
        return [] unless TudlaAccounting.attachments?

        record.attachments.includes(:blob).sort_by(&:created_at).map do |attachment|
          { id: attachment.id, filename: attachment.filename.to_s, content_type: attachment.content_type, byte_size: attachment.byte_size, created_at: time(attachment.created_at) }
        end
      end

      def tax_code_json(code)
        { id: code.id, code: code.code, name: code.name, kind: code.kind, rate: code.rate.to_s("F"), account_code: code.account&.code, active: code.active? }
      end

      def period_json(period)
        { id: period.id, label: period.label, kind: period.root? ? "year" : "month", year_id: period.root_id,
          from_date: date(period.from_date), thru_date: date(period.thru_date), closed: period.closed? }
      end
    end
  end
end
