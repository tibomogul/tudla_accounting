# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # A budget's amounts over some of its months, as a Statement of them: each account's
    # amount (its own and its sub-accounts', as balances add up), signed the natural way,
    # with the categories' totals and the net profit. Beside the actual statement in a
    # Comparison, it makes budget vs actual.
    #
    #   BudgetStatement.new(budget, budget.months.first(3), period: march) # January to March
    class BudgetStatement < Statement
      attr_reader :budget

      # period: the period the months make up or end in, for the page's links.
      def initialize(budget, months, period:, accounts: nil)
        @budget = budget
        @organization = budget.organization
        @period = period
        @accounts = accounts || Account.where(organization: organization).order(:code).to_a
        own = BudgetLine.where(budget: budget, period_id: months.map(&:id)).group(:account_id).sum(:amount_cents)
        children = @accounts.group_by(&:parent_id)
        rolled = ->(account) { own.fetch(account.id, 0) + children.fetch(account.id, []).sum { |child| rolled.call(child) } }
        @cents = @accounts.to_h { |account| [ account.id, rolled.call(account) ] }
      end

      def amount_of(account)
        Money.new(@cents.fetch(account.id), organization.currency)
      end
    end
  end
end
