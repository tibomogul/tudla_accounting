# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # A statement (BalanceSheet or ProfitAndLoss) for several periods side by side: one
    # report per period, in the order given, with rows lined up by account. An account
    # shows when it has something in any of the periods, under its parent as in the
    # single statement.
    #
    #   comparison = Comparison.new(ProfitAndLoss, organization, [ march, february ])
    #   comparison.rows("income")    # => [#<Row account=4000 depth=0 amounts=[$120, $100]>, ...]
    #   comparison.values(:net_profit) # => [$20, $15]
    class Comparison
      Row = Struct.new(:account, :depth, :amounts, keyword_init: true)

      attr_reader :reports

      def initialize(report_class, organization, periods)
        accounts = Account.where(organization: organization).order(:code).to_a
        @accounts = accounts
        @reports = periods.map { |period| report_class.new(organization, period, accounts: accounts) }
      end

      def periods
        reports.map(&:period)
      end

      # Rows for a category, in tree order, with an amount per period.
      def rows(category)
        children = @accounts.group_by(&:parent_id)
        walk = lambda do |account, depth|
          below = children.fetch(account.id, []).flat_map { |child| walk.call(child, depth + 1) }
          amounts = reports.map { |report| report.statement.natural_amount(account) }
          amounts.all?(&:zero?) && below.empty? ? [] : [ Row.new(account: account, depth: depth, amounts: amounts), *below ]
        end
        reports.first.statement.roots(category).flat_map { |account| walk.call(account, 0) }
      end

      # The category's total in each period.
      def total(category)
        reports.map { |report| report.total(category) }
      end

      # A report's figure (net_profit, total_equity...) in each period.
      def values(figure)
        reports.map { |report| report.public_send(figure) }
      end
    end
  end
end
