# frozen_string_literal: true

module TudlaAccounting
  # Balances are a cache of the posted entries (apart from opening balances, which exist
  # only in the first year's balances). This works out every balance again from the posted
  # lines, independently of the posting code, compares it with what is stored, and can
  # rewrite the stored balances to match:
  #
  #   rebuilder = BalanceRebuilder.new(organization)
  #   rebuilder.differences # => [#<Difference account=1010 period=Mar 2026 field=:ending_amount_cents stored=... expected=...>]
  #   rebuilder.rebuild!    # => the number of balances corrected
  #
  # The rules are the posting rules: a line counts in the month containing its entry's
  # posting time, for its account and every account above it (each on its own side); the
  # first year opens with the stored opening balances; within a year each period opens
  # where the one before it closed (the first where its parent opens); later years carry
  # balance-sheet accounts forward, restart income and expenses, and add the previous
  # year's profit to retained earnings and the accounts above it.
  class BalanceRebuilder
    FIELDS = %i[starting_amount_cents current_amount_cents ending_amount_cents].freeze

    Difference = Struct.new(:account, :period, :field, :stored, :expected, keyword_init: true) do
      def missing? = field == :missing
    end

    attr_reader :organization

    def initialize(organization)
      @organization = organization
      @accounts = TudlaAccounting::Account.where(organization: organization).to_a
      @periods = TudlaAccounting::Period.where(organization: organization).to_a
      @children = @periods.group_by(&:parent_id).transform_values { |periods| periods.sort_by(&:from_date) }
      @roots = @children.fetch(nil, [])
      @expected = {}
    end

    def differences
      @differences ||= stored_differences + missing_balances
    end

    # Rewrites the stored balances to the expected ones (creating any that are missing)
    # under the organization's posting lock. Returns how many balances changed.
    def rebuild!
      ActiveRecord::Base.transaction do
        organization.class.lock.find(organization.id)
        @expected = {}
        @movements = @openings = @differences = nil
        fixes = differences.group_by { |difference| [ difference.account, difference.period ] }
        fixes.each_key do |account, period|
          values = expected(account, period)
          balance = TudlaAccounting::Balance.find_or_initialize_by(account: account, period: period)
          balance.assign_attributes(values.merge(organization: organization, currency: currency))
          balance.save!
        end
        fixes.size
      end
    end

    # { starting_amount_cents:, current_amount_cents:, ending_amount_cents: } for an
    # account in a period, as the posted entries say it should be.
    def expected(account, period)
      @expected[[ account.id, period.id ]] ||= begin
        starting = starting_cents(account, period)
        current = current_cents(account, period)
        { starting_amount_cents: starting, current_amount_cents: current, ending_amount_cents: starting + current }
      end
    end

    private

    def currency
      organization.currency
    end

    def stored_differences
      TudlaAccounting::Balance.where(account: @accounts).includes(:account, :period).flat_map do |balance|
        values = expected(balance.account, balance.period)
        FIELDS.filter_map do |field|
          next if balance.public_send(field) == values[field]

          Difference.new(account: balance.account, period: balance.period, field: field, stored: balance.public_send(field), expected: values[field])
        end
      end
    end

    # Accounts with lines in a period that has no stored balance for them.
    def missing_balances
      stored = TudlaAccounting::Balance.where(account: @accounts).pluck(:account_id, :period_id).to_set
      @accounts.flat_map do |account|
        @periods.filter_map do |period|
          next if stored.include?([ account.id, period.id ]) || current_cents(account, period).zero?

          Difference.new(account: account, period: period, field: :missing, stored: nil, expected: current_cents(account, period))
        end
      end
    end

    # Movement in a period: the lines posted in it (or in the periods inside it).
    def current_cents(account, period)
      leaves(period).sum { |leaf| movements.dig(account.id, leaf.id).to_i }
    end

    def leaves(period)
      children = @children.fetch(period.id, [])
      children.empty? ? [ period ] : children.flat_map { |child| leaves(child) }
    end

    # { account_id => { leaf_period_id => cents } }, each line counted for its account and
    # every account above it, on that account's own side.
    def movements
      @movements ||= begin
        totals = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        by_id = @accounts.index_by(&:id)
        all_leaves = @roots.flat_map { |root| leaves(root) }
        TudlaAccounting::Detail.joins(:entry).where(account_id: by_id.keys).where.not(tudla_accounting_entries: { posted_at: nil })
          .pluck(:account_id, :tally, :amount_cents, "tudla_accounting_entries.posted_at").each do |account_id, tally, cents, posted_at|
            leaf = all_leaves.bsearch { |candidate| candidate.thru_date >= posted_at }
            next unless leaf&.includes_date?(posted_at)

            account = by_id.fetch(account_id)
            [ account, *account.ancestor_ids.map { |id| by_id.fetch(id) } ].each do |counted|
              debit = tally == Detail::TALLY_DEBIT
              totals[counted.id][leaf.id] += debit == counted.debit_balance? ? cents : -cents
            end
          end
        totals
      end
    end

    def starting_cents(account, period)
      parent = @periods.find { |candidate| candidate.id == period.parent_id }
      return year_opening_cents(account, period) unless parent

      siblings = @children.fetch(parent.id)
      earlier = siblings[siblings.index(period) - 1] if siblings.index(period).positive?
      earlier ? expected(account, earlier)[:ending_amount_cents] : expected(account, parent)[:starting_amount_cents]
    end

    def year_opening_cents(account, year)
      index = @roots.index(year)
      if index.zero?
        openings.fetch(account.id, 0)
      elsif account.balance_sheet_account?
        previous = @roots[index - 1]
        expected(account, previous)[:ending_amount_cents] + (takes_profit?(account) ? net_profit_cents(previous) : 0)
      else
        0
      end
    end

    # The opening balances: the stored starting amounts for the first year.
    def openings
      @openings ||= TudlaAccounting::Balance.where(account: @accounts, period: @roots.first).pluck(:account_id, :starting_amount_cents).to_h
    end

    def net_profit_cents(year)
      @accounts.select { |account| account.parent_id.nil? && !account.balance_sheet_account? }.sum do |account|
        ending = expected(account, year)[:ending_amount_cents]
        account.debit_balance? ? -ending : ending
      end
    end

    def takes_profit?(account)
      retained = retained_earnings
      retained.present? && (retained.id == account.id || retained.ancestor_ids.include?(account.id))
    end

    def retained_earnings
      return @retained_earnings if defined?(@retained_earnings)

      code = TudlaAccounting.configuration.retained_earnings_account_code
      @retained_earnings = code.present? ? @accounts.find { |account| account.code == code } : nil
    end
  end
end
