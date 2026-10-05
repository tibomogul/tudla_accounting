module TudlaAccounting
  module EntriesHelper
    def entry_status_badge(entry)
      entry.posted? ? tc_badge("Posted #{tc_date(entry.posted_at)}", tone: :success) : tc_badge("Draft", tone: :warning)
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
