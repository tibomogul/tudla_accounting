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

    # Posts amount on tally to this balance's account in its period; see BalancePoster.
    def post(amount, tally)
      raise ArgumentError, "amount must be a Money object" unless amount.is_a?(Money)
      raise ArgumentError, "tally must be debit or credit" unless [ TudlaAccounting::Detail::TALLY_DEBIT, TudlaAccounting::Detail::TALLY_CREDIT ].include?(tally)

      BalancePoster.new(organization).post(account, period, amount.cents, tally)
      reload
      true
    end

    class << self
      # The account's balance for a period, created (and stored) if it doesn't exist yet.
      def get(account, period)
        balance = peek(account, period)
        balance.save! if balance.new_record?
        balance
      end

      # The account's balance for a period without storing anything: the stored balance,
      # or a new unsaved one opening at what the period would open at. Use it to read.
      def peek(account, period)
        peek_all([ account ], period).fetch(account.id)
      end

      # { account_id => balance } for many accounts in one period, as peek gives each, in a
      # few queries whatever the number of accounts. A missing balance opens where the
      # account's most recent balance at the same level closed (periods without activity
      # have none, so that may be several back), else where its balance in the period
      # above opens, else by the year-end rules (see opening_for_year).
      def peek_all(accounts, period)
        accounts = accounts.to_a
        found = where(account_id: accounts.map(&:id), period_id: period.id).index_by(&:account_id)
        missing = accounts.reject { |account| found.key?(account.id) }
        return found if missing.empty?

        earlier_periods = period.root.subtree.at_depth(period.depth).where("from_date < ?", period.from_date)
        latest = where(account_id: missing.map(&:id), period_id: earlier_periods).includes(:period).group_by(&:account_id)
          .transform_values { |balances| balances.max_by { |balance| balance.period.from_date } }
        openings = missing.to_h { |account| [ account.id, latest[account.id]&.ending_amount_cents ] }

        unknown = missing.select { |account| openings[account.id].nil? }
        if unknown.any?
          from_above = period.has_parent? ? peek_all(unknown, period.parent).transform_values(&:starting_amount_cents) : openings_for_year(unknown, period)
          openings.merge!(from_above)
        end

        org = period.organization
        missing.each do |account|
          cents = openings.fetch(account.id)
          found[account.id] = new(account: account, period: period, starting_amount_cents: cents, current_amount_cents: 0,
                                  ending_amount_cents: cents, currency: org.currency, organization: org)
        end
        found
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
        BalancePoster.new(year.organization).carry_into_later_years(account, year, delta_cents)
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

      # { account_id => cents } each account opens a financial year (a root period) at:
      # asset, liability and equity accounts at their closing balance from the previous
      # year; income and expense accounts at zero; retained earnings (and the accounts above
      # it) also take in the previous year's net profit.
      def openings_for_year(accounts, year)
        org = year.organization
        previous_year = earlier_roots(year).order(:from_date).last
        carried = accounts.select(&:balance_sheet_account?)
        openings = accounts.to_h { |account| [ account.id, 0 ] }
        return openings unless previous_year && carried.any?

        closing = peek_all(carried, previous_year)
        retained_earnings = retained_earnings_account(org)
        takes_profit = retained_earnings ? [ retained_earnings.id, *retained_earnings.ancestor_ids ] : []
        profit = carried.any? { |account| takes_profit.include?(account.id) } ? net_profit(org, previous_year).cents : 0
        carried.each do |account|
          openings[account.id] = closing.fetch(account.id).ending_amount_cents + (takes_profit.include?(account.id) ? profit : 0)
        end
        openings
      end

      def earlier_roots(year)
        TudlaAccounting::Period.roots.where(organization: year.organization).where("from_date < ?", year.from_date)
      end
    end
  end
end
