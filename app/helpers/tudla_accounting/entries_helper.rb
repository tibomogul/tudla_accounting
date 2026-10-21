module TudlaAccounting
  module EntriesHelper
    def entry_status_badge(entry)
      entry.posted? ? tc_badge("Posted #{tc_date(entry.posted_at)}", tone: :success) : tc_badge("Draft", tone: :warning)
    end

    # The entry's journal number and particulars, e.g. "#42 Office rent" (a draft has no number).
    def entry_title(entry)
      [ entry.number_label, entry.particulars ].compact.join(" ")
    end

    # The accounts a line can choose: the active ones, and any the lines have already.
    # lines: an entry's details, or a recurring entry's lines.
    def entry_account_options(lines)
      used = lines.filter_map(&:account_id)
      TudlaAccounting::Account.where(organization: accounting_organization).active.or(TudlaAccounting::Account.where(id: used))
        .order(:code).map { |account| [ account_option_label(account), account.id ] }
    end

    # The tax codes a line can choose: the active ones, and any the lines have already. Each
    # carries its rate for the line editor's totals.
    def entry_tax_options(lines)
      used = lines.filter_map(&:tax_code_id)
      TudlaAccounting::TaxCode.where(organization: accounting_organization).where(active: true).or(TudlaAccounting::TaxCode.where(id: used))
        .order(:kind, :code).map { |code| [ code.label, code.id, { data: { rate: code.rate.to_s } } ] }
    end

    # [dimension, value choices] for the line editor: the active dimensions and values,
    # and any the lines have already.
    def entry_dimensions(lines)
      used = lines.flat_map { |line| line.respond_to?(:tags) ? line.tags.map(&:dimension_value_id) : line.dimension_value_ids }
      TudlaAccounting::Dimension.where(organization: accounting_organization).includes(:dimension_values).order(:code).filter_map do |dimension|
        values = dimension.dimension_values.select { |value| value.active? || used.include?(value.id) }
        [ dimension, values.map { |value| [ value.name, value.id ] } ] if (dimension.active? && values.any?) || values.any? { |value| used.include?(value.id) }
      end
    end

    # A link to what the entry was posted for (an invoice, bill, credit note or payment),
    # or to the entry itself.
    def entry_source_link(entry)
      source = entry.source if entry.source_type.in?([ Document.name, Payment.name ])
      case source
      when Document then link_to(source.title, document_path(source), class: "underline")
      when Payment then link_to(source.title, payment_path(source), class: "underline")
      else link_to(entry_title(entry), entry_path(entry), class: "underline")
      end
    end

    def entry_total(entry)
      entry.details.select(&:debit?).sum(Money.new(0, accounting_organization.currency), &:amount)
    end

    # A typed amount for the line editor: "1234.50", or "" when the line is on the other side.
    def entry_line_amount(detail, tally)
      return "" unless detail.amount_cents.to_i.positive? && detail.tally == tally

      detail.amount.format(symbol: false, thousands_separator: "")
    end
  end
end
