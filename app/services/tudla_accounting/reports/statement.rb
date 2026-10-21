# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # Account balances for one period, arranged for financial statements: by category,
    # each account under its parent, signed the natural way for its category (a contra
    # account shows as a deduction), skipping accounts with nothing in them.
    #
    #   Statement.new(organization, period, :ending_amount)  # balances at the period end
    #   Statement.new(organization, period, :current_amount) # movement during the period
    class Statement
      Row = Struct.new(:account, :depth, :amount, keyword_init: true)

      attr_reader :organization, :period

      # accounts: the organization's accounts in code order, when already loaded (a
      # Comparison shares them between its periods).
      def initialize(organization, period, amount = :ending_amount, accounts: nil)
        @organization = organization
        @period = period
        @amount = amount
        @accounts = accounts || TudlaAccounting::Account.where(organization: organization).order(:code).to_a
        @balances = TudlaAccounting::Balance.peek_all(@accounts, period)
      end

      # Rows for a category, in tree order.
      def rows(category)
        children = @accounts.group_by(&:parent_id)
        walk = lambda do |account, depth|
          below = children.fetch(account.id, []).flat_map { |child| walk.call(child, depth + 1) }
          own = Row.new(account: account, depth: depth, amount: natural_amount(account))
          own.amount.zero? && below.empty? ? [] : [ own, *below ]
        end
        roots(category).flat_map { |account| walk.call(account, 0) }
      end

      # The category's total: its top-level accounts, which include their sub-accounts.
      def total(category)
        roots(category).sum(Money.new(0, organization.currency)) { |account| natural_amount(account) }
      end

      # Income less expenses for the period.
      def net_profit
        total(Account::CATEGORY_INCOME) - total(Account::CATEGORY_EXPENSE)
      end

      # The account's own balance in the period, on its own side.
      def amount_of(account)
        Money.new(@balances.fetch(account.id).public_send("#{@amount}_cents"), organization.currency)
      end

      # The account's balance on its category's natural side, as the rows show it: a contra
      # account counts against its category.
      def natural_amount(account)
        account.contra? ? -amount_of(account) : amount_of(account)
      end

      def accounts
        @accounts
      end

      # The category's top-level accounts.
      def roots(category)
        @accounts.select { |account| account.parent_id.nil? && account.category == category }
      end
    end
  end
end
