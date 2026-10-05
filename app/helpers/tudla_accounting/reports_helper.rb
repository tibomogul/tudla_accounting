module TudlaAccounting
  module ReportsHelper
    SECTION_TITLES = { "asset" => "Assets", "liability" => "Liabilities", "equity" => "Equity",
                       "income" => "Income", "expense" => "Expenses" }.freeze
    AGING_BUCKETS = { current: "Current", days_1_30: "1–30 days", days_31_60: "31–60 days",
                      days_61_90: "61–90 days", days_over_90: "Over 90 days" }.freeze

    # The account's page, showing the year the report's period is in.
    def report_account_link(account, period)
      link_to account.name, account_path(account, year_id: period.root.id)
    end

    # "Acme Pty Ltd" for anything with a name, otherwise "Organization #4".
    def related_party_name(party)
      party.respond_to?(:name) && party.name.present? ? party.name : "#{party.class.name.demodulize} ##{party.id}"
    end
  end
end
