# frozen_string_literal: true

module TudlaAccounting
  class Balance < ApplicationRecord
    belongs_to :organization, polymorphic: true
    belongs_to :account, class_name: "TudlaAccounting::Account"
    belongs_to :period, class_name: "TudlaAccounting::Period"

    has_many :details, class_name: "TudlaAccounting::Detail", dependent: :destroy

    monetize :starting_amount_cents, with_model_currency: :currency
    monetize :current_amount_cents, with_model_currency: :currency
    monetize :ending_amount_cents, with_model_currency: :currency

    def update_current_amount(amount, tally)
      raise ArgumentError, "amount must be a Money object" unless amount.is_a?(Money)
      raise ArgumentError, "tally must be debit or credit" unless [ TudlaAccounting::Detail::TALLY_DEBIT, TudlaAccounting::Detail::TALLY_CREDIT ].include?(tally)

      transaction do
        should_add = (account.debit_balance? && tally == TudlaAccounting::Detail::TALLY_DEBIT) ||
                    (!account.debit_balance? && tally == TudlaAccounting::Detail::TALLY_CREDIT)

        self.current_amount = current_amount + (should_add ? amount : -amount)
        self.ending_amount = ending_amount + (should_add ? amount : -amount)

        save!
      end
    end

    def update_starting_amount(amount, tally)
      raise ArgumentError, "amount must be a Money object" unless amount.is_a?(Money)
      raise ArgumentError, "tally must be debit or credit" unless [ TudlaAccounting::Detail::TALLY_DEBIT, TudlaAccounting::Detail::TALLY_CREDIT ].include?(tally)

      transaction do
        should_add = (account.debit_balance? && tally == TudlaAccounting::Detail::TALLY_DEBIT) ||
                    (!account.debit_balance? && tally == TudlaAccounting::Detail::TALLY_CREDIT)

        self.starting_amount = starting_amount + (should_add ? amount : -amount)
        self.ending_amount = ending_amount + (should_add ? amount : -amount)

        save!
      end
    end

    def post_to_self_and_associated_period(amount, tally)
      raise ArgumentError, "amount must be a Money object" unless amount.is_a?(Money)
      raise ArgumentError, "tally must be debit or credit" unless [ TudlaAccounting::Detail::TALLY_DEBIT, TudlaAccounting::Detail::TALLY_CREDIT ].include?(tally)

      transaction do
        update_current_amount(amount, tally)
        delta_cents = signed_cents(amount, tally)

        if period.has_parent?
          # Later periods in the same year opened from this one.
          later_periods = period.siblings.where("from_date > ?", period.from_date)
          self.class.shift_balances(account, later_periods, delta_cents)

          Balance.get(account, period.parent).post_to_self_and_associated_period(amount, tally)
        else
          self.class.carry_into_later_years(account, period, delta_cents)
        end

        true
      end
    end

    def post(amount, tally)
      raise ArgumentError, "amount must be a Money object" unless amount.is_a?(Money)
      raise ArgumentError, "tally must be debit or credit" unless [ TudlaAccounting::Detail::TALLY_DEBIT, TudlaAccounting::Detail::TALLY_CREDIT ].include?(tally)

      transaction do
        post_to_self_and_associated_period(amount, tally)

        if account.parent
          parent_balance = Balance.get(account.parent, period)
          parent_balance.post(amount, tally)
        end

        true
      end
    end

    class << self
      def get(account, period)
        balance = find_by(account: account, period: period)
        return balance if balance

        org = period.organization
        # The account's most recent balance in an earlier period at the same level.
        # Periods without activity have no balance, so this may be several periods
        # back (e.g. January when nothing was posted in February).
        earlier_periods = period.root.subtree.at_depth(period.depth).where("from_date < ?", period.from_date)
        latest_earlier_balance = where(account: account, period: earlier_periods)
          .joins(:period).order(TudlaAccounting::Period.arel_table[:from_date].desc).first

        starting_amount = if latest_earlier_balance
          latest_earlier_balance.ending_amount
        elsif period.has_parent?
          get(account, period.parent).starting_amount
        else
          opening_for_year(account, period)
        end

        create!(
          account: account,
          period: period,
          starting_amount: starting_amount,
          current_amount: Money.new(0, org.currency),
          ending_amount: starting_amount,
          currency: org.currency,
          organization: org
        )
      end

      # Moves the account's existing balances in the given periods, and in the periods
      # inside them, by delta_cents (on the account's own side).
      def shift_balances(account, periods, delta_cents)
        return if delta_cents.zero?

        period_ids = periods.flat_map(&:subtree_ids)
        where(account: account, period_id: period_ids).update_all(
          [ "starting_amount_cents = starting_amount_cents + :delta, ending_amount_cents = ending_amount_cents + :delta", { delta: delta_cents } ]
        )
      end

      # Carries a change in a year's balance into later years that already have
      # balances, following the year-end rules in opening_for_year: asset, liability
      # and equity accounts carry their own balance; income and expense accounts
      # start each year at zero, and their effect on profit moves retained earnings
      # instead (once, at the top of the account tree).
      def carry_into_later_years(account, year, delta_cents)
        later_years = later_roots(year)

        if account.balance_sheet_account?
          shift_balances(account, later_years, delta_cents)
        elsif account.root? && (retained_earnings = retained_earnings_account(year.organization))
          profit_delta = account.debit_balance? ? -delta_cents : delta_cents
          [ retained_earnings, *retained_earnings.ancestors ].each do |equity_account|
            shift_balances(equity_account, later_years, profit_delta)
          end
        end
      end

      # The configured retained earnings account for an organization, if any.
      def retained_earnings_account(organization)
        code = TudlaAccounting.configuration.retained_earnings_account_code
        TudlaAccounting::Account.find_by(organization: organization, code: code) if code.present?
      end

      # Net profit for a year (income less expenses), from the top-level income and
      # expense accounts' balances.
      def net_profit(organization, year)
        accounts = TudlaAccounting::Account.roots.where(organization: organization,
                                                        category: [ Account::CATEGORY_INCOME, Account::CATEGORY_EXPENSE ])
        cents = where(period: year, account: accounts).includes(:account).sum do |balance|
          balance.account.debit_balance? ? -balance.ending_amount_cents : balance.ending_amount_cents
        end
        Money.new(cents, organization.currency)
      end

      private

      # Each root period is a financial year. Asset, liability and equity accounts open
      # with their closing balance from the previous year; income and expense accounts
      # open at zero; retained earnings (and the accounts above it) also take in the
      # previous year's net profit.
      def opening_for_year(account, year)
        org = year.organization
        previous_year = earlier_roots(year).order(:from_date).last
        return Money.new(0, org.currency) unless previous_year && account.balance_sheet_account?

        opening = get(account, previous_year).ending_amount
        retained_earnings = retained_earnings_account(org)
        if retained_earnings && (retained_earnings == account || retained_earnings.ancestor_ids.include?(account.id))
          opening += net_profit(org, previous_year)
        end
        opening
      end

      def earlier_roots(year)
        TudlaAccounting::Period.roots.where(organization: year.organization).where("from_date < ?", year.from_date)
      end

      def later_roots(year)
        TudlaAccounting::Period.roots.where(organization: year.organization).where("from_date > ?", year.from_date)
      end
    end

    private

    def signed_cents(amount, tally)
      should_add = (account.debit_balance? && tally == TudlaAccounting::Detail::TALLY_DEBIT) ||
                   (!account.debit_balance? && tally == TudlaAccounting::Detail::TALLY_CREDIT)
      should_add ? amount.cents : -amount.cents
    end
  end
end
