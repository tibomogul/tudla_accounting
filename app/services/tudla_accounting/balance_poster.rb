# frozen_string_literal: true

module TudlaAccounting
  # Moves balances for a posting, in as few statements as it can: an amount posted to an
  # account in a period goes into
  #   - the current and ending amounts of that period and every period above it (the
  #     month, its quarter, its year), for the account and every account above it, each on
  #     its own side;
  #   - the starting and ending amounts of every later period within those (later months
  #     in the year...), which open where the earlier ones close;
  #   - later years, by the year-end rules (see carry_into_later_years).
  # Missing balances are created first, opening where they should before anything moves.
  #
  # One poster serves a whole entry: it caches the account and period chains, the later
  # periods and the retained earnings accounts it looks up. Callers hold the
  # organization's posting lock.
  class BalancePoster
    def initialize(organization)
      @organization = organization
      @leaf_periods = {}
      @account_chains = {}
      @period_chains = {}
      @later_period_ids = {}
      @later_year_ids = {}
    end

    # The month (leaf period) a posting at this time goes into; raises when there is none,
    # more than one, or it is closed.
    def leaf_period_for(posted_at)
      @leaf_periods[posted_at] ||= begin
        periods = Period.leaf_periods_for_date(@organization, posted_at).to_a
        raise ArgumentError, "no valid period found for the posted date" if periods.empty?
        raise ArgumentError, "multiple periods found for the posted date" if periods.size > 1
        raise ArgumentError, "the period for the posted date is closed" if periods.first.closed?

        periods.first
      end
    end

    # Posts cents on tally to account in period. Returns the account's balance for period.
    def post(account, period, cents, tally)
      accounts = account_chain(account)
      periods = period_chain(period)
      balance = ensure_balances(accounts, periods, account, period)
      later = later_period_ids(period)

      deltas = accounts.to_h { |each_account| [ each_account, (tally == Detail::TALLY_DEBIT) == each_account.debit_balance? ? cents : -cents ] }
      move(:current_amount_cents, deltas, periods.map(&:id))
      move(:starting_amount_cents, deltas, later)
      move(:starting_amount_cents, carried(deltas, periods.last), later_year_ids(periods.last))
      balance
    end

    # Carries a change in a year's balance into later years that have balances: asset,
    # liability and equity accounts carry their own; income and expense accounts start
    # each year at zero, and their effect on profit moves retained earnings (and the
    # accounts above it) instead, once, at the top of the account tree.
    def carry_into_later_years(account, year, delta)
      move(:starting_amount_cents, carried({ account => delta }, year), later_year_ids(year))
    end

    private

    # What a year's changes (account => delta) carry into later years: balance-sheet
    # accounts their own; a top-level income or expense account its effect on profit, into
    # retained earnings and the accounts above it.
    def carried(deltas, _year)
      deltas.each_with_object(Hash.new(0)) do |(account, delta), carry|
        if account.balance_sheet_account?
          carry[account] += delta
        elsif account.root?
          retained_earnings_chain.each { |equity_account| carry[equity_account] += account.debit_balance? ? -delta : delta }
        end
      end
    end

    # Adds each account's delta to the column (current or starting) and the ending amount of
    # its balances in the periods, in one statement.
    def move(column, deltas, period_ids)
      deltas = deltas.reject { |_account, delta| delta.zero? }
      return if deltas.empty? || period_ids.empty?

      by_account = deltas.map { |account, delta| "WHEN #{Integer(account.id)} THEN #{Integer(delta)}" }.join(" ")
      Balance.where(account_id: deltas.keys.map(&:id), period_id: period_ids)
        .update_all("#{column} = #{column} + CASE account_id #{by_account} END, ending_amount_cents = ending_amount_cents + CASE account_id #{by_account} END")
    end

    # The balances the posting moves, created where missing (in order, so each opens from
    # the ones before it). Returns the one for account in period.
    def ensure_balances(accounts, periods, account, period)
      existing = Balance.where(account_id: accounts.map(&:id), period_id: periods.map(&:id)).index_by { |b| [ b.account_id, b.period_id ] }
      accounts.each do |each_account|
        periods.reverse_each do |each_period|
          existing[[ each_account.id, each_period.id ]] ||= Balance.get(each_account, each_period)
        end
      end
      existing.fetch([ account.id, period.id ])
    end

    # The account and every account above it.
    def account_chain(account)
      @account_chains[account.id] ||= [ account, *account.ancestors.reverse ]
    end

    # The period and every period above it, up to its year.
    def period_chain(period)
      @period_chains[period.id] ||= [ period, *period.ancestors.reverse ]
    end

    # Periods after the posted one within each period above it (later months of its
    # quarter, later quarters of its year...), with everything inside them.
    def later_period_ids(period)
      @later_period_ids[period.id] ||= period_chain(period).each_cons(2).flat_map do |inner, outer|
        outer.subtree.where("from_date > ?", inner.thru_date).pluck(:id)
      end
    end

    # Every period of the years after this one.
    def later_year_ids(year)
      @later_year_ids[year.id] ||= begin
        later_roots = Period.roots.where(organization: @organization).where("from_date > ?", year.from_date).pluck(:id).to_set
        later_roots.empty? ? [] : Period.where(organization: @organization).select { |period| later_roots.include?(period.root_id) }.map(&:id)
      end
    end

    def retained_earnings_chain
      return @retained_earnings_chain if defined?(@retained_earnings_chain)

      retained = Balance.retained_earnings_account(@organization)
      @retained_earnings_chain = retained ? [ retained, *retained.ancestors ] : []
    end
  end
end
