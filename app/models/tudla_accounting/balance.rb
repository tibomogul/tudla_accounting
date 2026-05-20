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

        period_siblings = period.siblings.where("from_date > ?", period.from_date).order(:from_date)
        period_siblings.each do |period_sibling|
          period_sibling.subtree.each do |period|
            period_balance = TudlaAccounting::Balance.find_by(account: account, period: period)
            period_balance&.update_starting_amount(amount, tally)
          end
        end

        if period.has_parent?
          parent_balance = Balance.get(account, period.parent)
          parent_balance.post_to_self_and_associated_period(amount, tally)
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
        same_level_periods = period.root.subtree.at_depth(period.depth)
        closest_left_period = same_level_periods.where("from_date < ?", period.from_date).order(:from_date).last

        starting_amount = if closest_left_period
          sibling_balance = find_by(account: account, period: closest_left_period)
          sibling_balance&.ending_amount || Money.new(0, org.currency)
        else
          if period.has_parent?
            parent_balance = get(account, period.parent)
            parent_balance.starting_amount
          else
            Money.new(0, org.currency)
          end
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
    end
  end
end
