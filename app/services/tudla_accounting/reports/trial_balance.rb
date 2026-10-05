# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # Every account's own balance (net of its sub-accounts, so nothing is counted twice) at
    # the end of a period, in debit and credit columns. The columns total the same when
    # the books balance.
    class TrialBalance
      Row = Struct.new(:account, :debit, :credit, keyword_init: true)

      attr_reader :statement

      delegate :period, to: :statement

      def initialize(organization, period)
        @organization = organization
        @statement = Statement.new(organization, period, :ending_amount)
      end

      def rows
        @rows ||= begin
          children = statement.accounts.group_by(&:parent_id)
          statement.accounts.filter_map do |account|
            own = own_balance(account, children.fetch(account.id, []))
            next if own.zero?

            debit_side = account.debit_balance? == own.positive?
            Row.new(account: account, debit: (own.abs if debit_side), credit: (own.abs unless debit_side))
          end
        end
      end

      def total_debits
        rows.filter_map(&:debit).sum(zero)
      end

      def total_credits
        rows.filter_map(&:credit).sum(zero)
      end

      def balanced?
        total_debits == total_credits
      end

      private

      def zero
        Money.new(0, @organization.currency)
      end

      # A parent's balance includes its sub-accounts' (each counted on the parent's side).
      def own_balance(account, children)
        children.reduce(statement.amount_of(account)) do |own, child|
          child_amount = statement.amount_of(child)
          own - (child.debit_balance? == account.debit_balance? ? child_amount : -child_amount)
        end
      end
    end
  end
end
