# frozen_string_literal: true

module TudlaAccounting
  # Profit and loss broken down by a dimension's values, from the lines posted in a span
  # of time (balances aren't kept per dimension):
  #
  #   DimensionReport.call(organization, department, from: year.from_date, thru: year.thru_date)
  #   # => { columns: [value, ..., nil], income: [row, ...], expense: [row, ...], totals: { income:, expense:, net_profit: } }
  #
  # A column per value (the active ones, and inactive ones with postings) and nil for
  # lines not tagged with the dimension, when there are any. Each row is
  # { account:, amounts: { column => Money }, total: Money } for an income or expense
  # account with postings: income counts credits up, expenses debits, so returns and
  # refunds show as negative amounts. totals hold { column => Money } plus :total.
  class DimensionReport
    def self.call(...)
      new(...).call
    end

    def initialize(organization, dimension, from:, thru:)
      raise ArgumentError, "The dimension belongs to another organization" unless dimension.organization == organization

      @organization = organization
      @dimension = dimension
      @from = from
      @thru = thru
    end

    def call
      columns = @dimension.dimension_values.select { |value| value.active? || used_value_ids.include?(value.id) }
      columns << nil if used_value_ids.include?(nil)
      accounts = Account.where(id: sums.keys.map(&:first).uniq).order(:code).to_a

      income = rows(accounts.select(&:income?), columns) { |credits, debits| credits - debits }
      expense = rows(accounts.select(&:expense?), columns) { |credits, debits| debits - credits }
      income_totals = column_totals(income, columns)
      expense_totals = column_totals(expense, columns)
      net = (columns + [ :total ]).index_with { |column| income_totals[column] - expense_totals[column] }

      { columns: columns, income: income, expense: expense, totals: { income: income_totals, expense: expense_totals, net_profit: net },
        dimension: @dimension, from: @from, thru: @thru }
    end

    private

    # { [account_id, dimension_value_id or nil, tally] => cents } for the span's income and
    # expense lines.
    def sums
      @sums ||= Detail.joins(:entry, :account)
        .joins(ActiveRecord::Base.sanitize_sql_array([ "LEFT JOIN tudla_accounting_detail_tags tags ON tags.detail_id = tudla_accounting_details.id AND tags.dimension_id = ?", @dimension.id ]))
        .where(organization_type: @organization.class.name, organization_id: @organization.id)
        .where(tudla_accounting_entries: { posted_at: @from..@thru })
        .where(tudla_accounting_accounts: { category: [ Account::CATEGORY_INCOME, Account::CATEGORY_EXPENSE ] })
        .group(:account_id, "tags.dimension_value_id", :tally).sum(:amount_cents)
    end

    def used_value_ids
      @used_value_ids ||= sums.keys.map { |key| key[1] }.to_set
    end

    def rows(accounts, columns)
      accounts.map do |account|
        amounts = columns.index_with do |column|
          value_id = column&.id
          money(yield(sums.fetch([ account.id, value_id, Detail::TALLY_CREDIT ], 0), sums.fetch([ account.id, value_id, Detail::TALLY_DEBIT ], 0)))
        end
        { account: account, amounts: amounts, total: amounts.values.sum(money(0)) }
      end
    end

    def column_totals(rows, columns)
      totals = columns.index_with { |column| rows.sum(money(0)) { |row| row[:amounts][column] } }
      totals.merge(total: rows.sum(money(0)) { |row| row[:total] })
    end

    def money(cents)
      Money.new(cents, @organization.currency)
    end
  end
end
