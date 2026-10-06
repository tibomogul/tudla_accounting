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

      def initialize(organization, period, amount = :ending_amount)
        @organization = organization
        @period = period
        @amount = amount
        @accounts = TudlaAccounting::Account.where(organization: organization).order(:code).to_a
        @balances = TudlaAccounting::Balance.peek_all(@accounts, period)
      end

      # Rows for a category, in tree order.
      def rows(category)
        children = @accounts.group_by(&:parent_id)
        walk = lambda do |account, depth|
          below = children.fetch(account.id, []).flat_map { |child| walk.call(child, depth + 1) }
          own = Row.new(account: account, depth: depth, amount: natural(account))
          own.amount.zero? && below.empty? ? [] : [ own, *below ]
        end
        roots(category).flat_map { |account| walk.call(account, 0) }
      end

      # The category's total: its top-level accounts, which include their sub-accounts.
      def total(category)
        roots(category).sum(Money.new(0, organization.currency)) { |account| natural(account) }
      end

      # Income less expenses for the period.
      def net_profit
        total(Account::CATEGORY_INCOME) - total(Account::CATEGORY_EXPENSE)
      end

      # The account's own balance in the period, on its own side.
      def amount_of(account)
        Money.new(@balances.fetch(account.id).public_send("#{@amount}_cents"), organization.currency)
      end

      def accounts
        @accounts
      end

      private

      def roots(category)
        @accounts.select { |account| account.parent_id.nil? && account.category == category }
      end

      # On the category's natural side: a contra account counts against its category.
      def natural(account)
        account.contra? ? -amount_of(account) : amount_of(account)
      end
    end
  end
end
