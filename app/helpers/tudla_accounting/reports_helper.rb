module TudlaAccounting
  module ReportsHelper
    SECTION_TITLES = { "asset" => "Assets", "liability" => "Liabilities", "equity" => "Equity",
                       "income" => "Income", "expense" => "Expenses" }.freeze
    AGING_BUCKETS = { current: "Current", days_1_30: "1–30 days", days_31_60: "31–60 days",
                      days_61_90: "61–90 days", days_over_90: "Over 90 days" }.freeze

    # The account's page, showing the year the report's period is in.
    # A comparison's column heading: "Mar 2026", "Year 2026", or "Total" for the year after
    # its months.
    def comparison_label(period, compare)
      return "Total" if compare == "months" && period.root?

      period.root? ? "Year #{tc_period_label(period)}" : tc_period_label(period)
    end

    # The change from the second amount to the first, as a percentage of the second
    # ("12.5%"), or "—" when the second is zero.
    def comparison_percent(amounts)
      base = amounts[1]
      return "—" if base.zero?

      "#{number_with_precision((amounts[0] - base).cents.to_f / base.cents.abs * 100, precision: 1, separator: tc_number_format.decimal_mark)}%"
    end

    # The column groups of budget vs actual: the period ("Mar 2026", "Year 2026"), then
    # the year to date for a month.
    def budget_column_groups(comparison)
      [ comparison_label(comparison.period, nil), *("Year to date" if comparison.year_to_date?) ]
    end

    # Whether a variance is good news: more income or profit than budgeted, or less
    # spending. Nil when there is none.
    def favourable_variance?(variance, category)
      return if variance.zero?

      category == Account::CATEGORY_EXPENSE ? variance.negative? : variance.positive?
    end

    def report_account_link(account, period)
      link_to account.name, account_path(account, year_id: period.root_id)
    end

    # "Acme Pty Ltd" for anything with a name, otherwise "Organization #4".
    def related_party_name(party)
      party.respond_to?(:name) && party.name.present? ? party.name : "#{party.class.name.demodulize} ##{party.id}"
    end
  end
end
