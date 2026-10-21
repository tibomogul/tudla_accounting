# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # Budget vs actual: a period's actual profit and loss beside a budget's, as a
    # Comparison, the actual results first in each pair. For a month, the year to date
    # follows (income and expense balances restart each year, so a month's ending
    # balances are its year to date).
    #
    #   comparison = BudgetComparison.new(budget, march)
    #   comparison.rows("income") # => [#<Row account=4000 amounts=[actual, budget, actual YTD, budget YTD]>, ...]
    class BudgetComparison < Comparison
      attr_reader :budget, :period

      def initialize(budget, period)
        @budget = budget
        @period = period
        organization = budget.organization
        @accounts = Account.where(organization: organization).order(:code).to_a
        months = budget.months
        @reports = [ Statement.new(organization, period, :current_amount, accounts: @accounts),
                     BudgetStatement.new(budget, months.select { |month| period.includes_date?(month.from_date) }, period: period, accounts: @accounts) ]
        return if period.root?

        @reports += [ Statement.new(organization, period, :ending_amount, accounts: @accounts),
                      BudgetStatement.new(budget, months.select { |month| month.from_date <= period.from_date }, period: period, accounts: @accounts) ]
      end

      # Whether the year to date follows the period's columns.
      def year_to_date?
        reports.size == 4
      end
    end
  end
end
