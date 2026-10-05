# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # Assets, liabilities and equity at the end of a period (usually a month), with the
    # year's profit so far as current-year earnings, which balances it.
    class BalanceSheet
      SECTIONS = [ Account::CATEGORY_ASSET, Account::CATEGORY_LIABILITY, Account::CATEGORY_EQUITY ].freeze

      attr_reader :statement

      delegate :period, :rows, :total, to: :statement

      def initialize(organization, period)
        @statement = Statement.new(organization, period, :ending_amount)
      end

      # Income less expenses from the start of the year to the period end (income and
      # expense balances restart each year, so their period-end balances are the year to date).
      def current_year_earnings
        statement.net_profit
      end

      def total_equity
        total(Account::CATEGORY_EQUITY) + current_year_earnings
      end

      def liabilities_and_equity
        total(Account::CATEGORY_LIABILITY) + total_equity
      end

      def difference
        total(Account::CATEGORY_ASSET) - liabilities_and_equity
      end

      def balanced?
        difference.zero?
      end
    end
  end
end
