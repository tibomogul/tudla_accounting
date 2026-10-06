module TudlaAccounting
  module EntriesHelper
    def entry_status_badge(entry)
      entry.posted? ? tc_badge("Posted #{tc_date(entry.posted_at)}", tone: :success) : tc_badge("Draft", tone: :warning)
    end

    # The tax codes a line can choose: the active ones, and any already on the entry. Each
    # carries its rate for the line editor's totals.
    def entry_tax_options(entry)
      used = entry.details.filter_map(&:tax_code_id)
      TudlaAccounting::TaxCode.where(organization: accounting_organization).where(active: true).or(TudlaAccounting::TaxCode.where(id: used))
        .order(:kind, :code).map { |code| [ code.label, code.id, { data: { rate: code.rate.to_s } } ] }
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
