# frozen_string_literal: true

module TudlaAccounting
  # A budget laid out as its page and spreadsheet show it: income, then expenses, each
  # account under its parent, a column per month. Accounts without sub-accounts take
  # amounts; an account with sub-accounts shows what they add up to, and, when amounts
  # were put on it directly (before it had sub-accounts, say), a row of its own for them.
  # Inactive accounts show only when they have amounts.
  #
  # read reads a spreadsheet back (as to_table writes it, or any with a Code column and
  # a column per month).
  class BudgetGrid
    Row = Struct.new(:account, :depth, :kind, keyword_init: true) do
      def input? = kind != :parent
    end

    MONTH_HEADINGS = [ "%b-%y", "%b %Y", "%B %Y", "%Y-%m", "%m/%Y" ].freeze # "%b %Y" would read "Mar-26" as the year -26

    attr_reader :budget, :amounts

    # amounts: { account_id => { period_id => cents } } to show instead of the budget's
    # (what was typed, when it couldn't be saved).
    def initialize(budget, amounts: nil)
      @budget = budget
      @accounts = Budget.accounts(budget.organization).to_a
      @children = @accounts.group_by(&:parent_id)
      @amounts = amounts || budget.amounts
    end

    def months
      budget.months
    end

    def categories
      Budget::CATEGORIES
    end

    # The rows of a category, in tree order.
    def rows(category)
      (@rows ||= {})[category] ||= @accounts.select { |account| account.parent_id.nil? && account.category == category }.flat_map { |account| walk(account, 0) }
    end

    # The account's own amount for a month, in cents.
    def amount(account, month)
      @amounts.dig(account.id, month.id).to_i
    end

    # What the account and its sub-accounts add up to for a month (or, with no month, the
    # year).
    def total(account, month = nil)
      own = month ? amount(account, month) : months.sum { |each| amount(account, each) }
      own + @children.fetch(account.id, []).sum { |child| total(child, month) }
    end

    # The category's total for a month (or the year): its accounts' amounts, a contra
    # account's deducted.
    def section_total(category, month = nil)
      rows(category).select(&:input?).sum do |row|
        cents = month ? amount(row.account, month) : months.sum { |each| amount(row.account, each) }
        row.account.contra? ? -cents : cents
      end
    end

    def net_profit(month = nil)
      section_total(Account::CATEGORY_INCOME, month) - section_total(Account::CATEGORY_EXPENSE, month)
    end

    # The budget for downloading: a row for each account taking amounts, then each
    # section's total and the net profit.
    def to_table
      money = ->(cents) { cents.zero? ? nil : Money.new(cents, budget.organization.currency) }
      money_total = ->(cents) { Money.new(cents, budget.organization.currency) }
      rows = categories.flat_map do |category|
        title = AccountsHelper::CATEGORY_LABELS.fetch(category)
        inputs = rows(category).select(&:input?).map do |row|
          name = row.kind == :own ? "#{row.account.name} (own)" : row.account.name
          [ title, row.account.code, name, *months.map { |month| money.call(amount(row.account, month)) }, money.call(months.sum { |month| amount(row.account, month) }) ]
        end
        [ *inputs, Reports::Table.total([ title, nil, "Total #{title.downcase}", *months.map { |month| money_total.call(section_total(category, month)) },
                                          money_total.call(section_total(category)) ]) ]
      end
      rows << Reports::Table.total([ nil, nil, "Net profit (loss)", *months.map { |month| money_total.call(net_profit(month)) }, money_total.call(net_profit) ])
      Reports::Table.new([ [ "Section", "Code", "Account", *months.map(&:label), "Total" ], *rows ])
    end

    # The amounts in a CSV or XLSX file ({ account_id => { period_id => cents } }) for
    # Budget#set_amounts!: its rows matched to accounts by the Code column, its columns to
    # the year's months by their headings ("Mar 2026", "2026-03" and the like, or dates).
    # Rows without a code (totals) and other columns are left out; a blank amount is
    # zero. Raises ArgumentError saying what can't be read.
    def read(path, extension)
      sheet = SpreadsheetRows.read(path, extension)
      headings = sheet.first.to_a
      code_column = headings.index { |heading| heading.to_s.strip.casecmp?("code") } || raise(ArgumentError, "The file has no Code column")
      month_columns = headings.each_with_index.filter_map { |heading, index| [ index, month_for(heading) ] if month_for(heading) }
      raise ArgumentError, "The file has no columns for the months of #{budget.period.label}" if month_columns.empty?

      by_code = @accounts.index_by(&:code)
      problems = []
      read = {}
      sheet.drop(1).each.with_index(2) do |row, number|
        code = row[code_column].to_s.strip.delete_suffix(".0")
        next if code.empty?

        account = by_code[code]
        next problems << "Row #{number}: no income or expense account has the code #{code}" unless account
        next problems << "Row #{number}: #{code} is in the file twice" if read.key?(account.id)

        read[account.id] = month_columns.to_h do |index, month|
          [ month.id, cents_in(row[index]) { problems << "Row #{number}, #{month.label}: #{row[index]} isn't an amount" } ]
        end
      end
      raise ArgumentError, problems.first(10).join("; ") if problems.any?

      read
    end

    private

    def walk(account, depth)
      return [] unless shown?(account)

      below = @children.fetch(account.id, [])
      return [ Row.new(account: account, depth: depth, kind: :account) ] if below.empty?

      own = @amounts[account.id].present? ? [ Row.new(account: account, depth: depth + 1, kind: :own) ] : []
      [ Row.new(account: account, depth: depth, kind: :parent), *own, *below.flat_map { |child| walk(child, depth + 1) } ]
    end

    def shown?(account)
      account.active? || @amounts[account.id].present? || @children.fetch(account.id, []).any? { |child| shown?(child) }
    end

    # The year's month a heading names, if any.
    def month_for(heading)
      date = case heading
      when Date, Time then heading.to_date
      when String then MONTH_HEADINGS.lazy.filter_map { |format| parse_date(heading.strip, format) }.first
      end
      date && months.find { |month| month.from_date.to_date.beginning_of_month == date.beginning_of_month }
    end

    def parse_date(text, format)
      Date.strptime(text, format)
    rescue Date::Error
      nil
    end

    def cents_in(cell)
      AmountParser.cents(cell, budget.organization.currency, round: true) || 0
    rescue ArgumentError
      yield
      0
    end
  end
end
