# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # Income and expenses for a period (a year or a month): what moved during it.
    class ProfitAndLoss
      SECTIONS = [ Account::CATEGORY_INCOME, Account::CATEGORY_EXPENSE ].freeze

      attr_reader :statement

      delegate :period, :rows, :total, :net_profit, to: :statement

      def initialize(organization, period)
        @statement = Statement.new(organization, period, :current_amount)
      end
    end
  end
end
