# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # Where cash came from and went over a run of months, by the operating, investing or
    # financing activity of the accounts involved (see Account#cash_flow_section). Moves
    # between cash accounts cancel out.
    #
    # The direct method attributes every posted entry that moves cash to its other lines,
    # which add up to exactly the cash moved (entries balance). The indirect method starts
    # from the net profit and adds each other balance-sheet account's change over the time
    # (credits less debits of its posted lines: receivables growing take cash, payables
    # growing give it); income and expense accounts are all in the net profit. Both come
    # from the same lines, so they arrive at the same net change.
    #
    #   flow = CashFlow.new(organization, from: march, thru: june, cash_accounts: [bank], method: :indirect)
    #   flow.sections # => { "operating" => [#<Row label="Net profit" ...>, #<Row account=1100 amount=...>, ...], "investing" => [...], "financing" => [...] }
    #   flow.opening + flow.net_change == flow.closing
    #
    # Cash is the cash_accounts given, or those set by the cash_account_codes setting, each
    # with every account beneath it. Inflows are positive, outflows negative.
    class CashFlow
      Row = Struct.new(:account, :amount, :label, keyword_init: true)
      ACTIVITIES = %w[operating investing financing].freeze
      METHODS = %i[direct indirect].freeze

      attr_reader :from, :thru, :cash_accounts, :flow_method

      def initialize(organization, from:, thru:, cash_accounts: nil, method: :direct)
        @organization = organization
        @from = from
        @thru = thru
        @cash_accounts = top_level(cash_accounts || configured_cash_accounts)
        @flow_method = method.to_sym
        raise ArgumentError, "method must be one of #{METHODS.join(', ')}" unless METHODS.include?(@flow_method)
      end

      def configured?
        cash_accounts.any?
      end

      def sections
        @sections ||= begin
          rows = contributions.map { |account_id, cents| Row.new(account: accounts.fetch(account_id), amount: money(cents)) }
            .reject { |row| row.amount.zero? }.sort_by { |row| row.account.code }
          if @flow_method == :indirect
            profit, rows = rows.partition { |row| !row.account.balance_sheet_account? }
            net_profit = Row.new(label: "Net profit", amount: profit.sum(zero, &:amount))
          end
          ACTIVITIES.index_with do |activity|
            in_activity = rows.select { |row| activity_of(row.account) == activity }
            activity == "operating" && net_profit ? [ net_profit, *in_activity ] : in_activity
          end
        end
      end

      def total(activity)
        sections.fetch(activity).sum(zero, &:amount)
      end

      def net_change
        ACTIVITIES.sum(zero) { |activity| total(activity) }
      end

      def opening
        balances = Balance.peek_all(cash_accounts, from)
        cash_accounts.sum(zero) { |account| debit_positive(account, balances.fetch(account.id).starting_amount) }
      end

      def closing
        balances = Balance.peek_all(cash_accounts, thru)
        cash_accounts.sum(zero) { |account| debit_positive(account, balances.fetch(account.id).ending_amount) }
      end

      # The cash accounts' change equals what the sections explain.
      def reconciles?
        opening + net_change == closing
      end

      private

      def configured_cash_accounts
        codes = Array(TudlaAccounting.configuration.cash_account_codes)
        codes.empty? ? [] : Account.where(organization: @organization, code: codes).to_a
      end

      # Drops accounts beneath another chosen one, so nothing is counted twice.
      def top_level(chosen)
        ids = chosen.map(&:id).to_set
        chosen.reject { |account| account.ancestor_ids.any? { |id| ids.include?(id) } }.sort_by(&:code)
      end

      def cash_ids
        @cash_ids ||= cash_accounts.flat_map(&:subtree_ids).to_set
      end

      # { account_id => cents } of credits less debits to accounts other than cash: on the
      # direct method, the other lines of entries moving cash (a credit to another account
      # brought cash in, a debit sent it out); on the indirect method, every line posted in
      # the time.
      def contributions
        @contributions ||= begin
          in_time = Detail.joins(:entry).where(tudla_accounting_entries: { posted_at: from.from_date..thru.thru_date })
          lines = if @flow_method == :indirect
            in_time.where(organization_type: @organization.class.name, organization_id: @organization.id)
          else
            Detail.where(entry_id: in_time.where(account_id: cash_ids.to_a).distinct.select(:entry_id))
          end
          lines.where.not(account_id: cash_ids.to_a).group(:account_id, :tally).sum(:amount_cents)
            .each_with_object(Hash.new(0)) do |((account_id, tally), cents), totals|
              totals[account_id] += tally == Detail::TALLY_CREDIT ? cents : -cents
            end
        end
      end

      def accounts
        @accounts ||= Account.where(id: contributions.keys).index_by(&:id)
      end

      def activity_of(account)
        (@activities ||= {})[account.id] ||= account.cash_flow_section
      end

      def debit_positive(account, amount)
        account.debit_balance? ? amount : -amount
      end

      def money(cents)
        Money.new(cents, @organization.currency)
      end

      def zero
        money(0)
      end
    end
  end
end
