# frozen_string_literal: true

module TudlaAccounting
  # Creates a chart of accounts and its opening balances from rows of a spreadsheet,
  # all or nothing. CsvLoader and XlsxLoader read the file; columns:
  #
  #   Account Code | Account Name | Account Type | Contra Code | Starting Balance | Parent Account Code
  #
  # Account Type is Asset(s), Liability/Liabilities, Equity, Income, Revenue or Expense(s).
  # Contra Code is the code of the account a contra account offsets. Starting balances are
  # signed the natural way for the category, so each parent equals the sum of its
  # children (contra accounts are negative); see StartingBalanceCreator. Parents and
  # contra targets must be in the same file. Existing accounts raise unless
  # overwrite_mode is set, in which case they are reused and their balances replaced.
  class ChartOfAccountsLoader
    CATEGORY_MAP = {
      "asset" => Account::CATEGORY_ASSET,
      "assets" => Account::CATEGORY_ASSET,
      "liability" => Account::CATEGORY_LIABILITY,
      "liabilities" => Account::CATEGORY_LIABILITY,
      "equity" => Account::CATEGORY_EQUITY,
      "income" => Account::CATEGORY_INCOME,
      "revenue" => Account::CATEGORY_INCOME,
      "expense" => Account::CATEGORY_EXPENSE,
      "expenses" => Account::CATEGORY_EXPENSE
    }.freeze

    attr_reader :organization, :file, :date, :overwrite_mode

    def self.call(...)
      new(...).call
    end

    def initialize(organization, file, date, overwrite_mode = false)
      @organization = organization
      @file = file
      @date = date
      @overwrite_mode = overwrite_mode
    end

    def call
      rows = read_rows.map { |row| parse(row) }
      ActiveRecord::Base.transaction do
        accounts = create_accounts(rows)
        link_accounts(rows, accounts)
        StartingBalanceCreator.call(organization, date, balance_nodes(rows, accounts), organization.currency, overwrite_mode)
      end
    end

    private

    # Returns an array of hashes keyed by column header.
    def read_rows
      raise NotImplementedError
    end

    def parse(row)
      code = code_value(row["Account Code"])
      raise ArgumentError, "A row has no Account Code" if code.blank?

      {
        code: code,
        name: row["Account Name"].to_s.strip,
        type: row["Account Type"].to_s.strip,
        parent_code: code_value(first_code(row["Parent Account Code"])),
        contra_code: code_value(row["Contra Code"]),
        amount_cents: amount_cents(row["Starting Balance"], code)
      }
    end

    # A parent cell may list several codes ("1010,1000"); the first is the parent.
    def first_code(value)
      value.is_a?(String) ? value.split(",").first : value
    end

    # Spreadsheets often store codes as numbers (1020 or 1020.0).
    def code_value(value)
      value = value.to_i if value.is_a?(Float) && value == value.floor
      value.to_s.strip.presence
    end

    def amount_cents(value, code)
      text = value.to_s.strip.delete(",")
      return 0 if text.empty?

      Money.from_amount(BigDecimal(text), organization.currency).cents
    rescue ArgumentError
      raise ArgumentError, "Starting Balance #{value.inspect} for account #{code} is not a number"
    end

    def create_accounts(rows)
      duplicate = rows.map { |row| row[:code] }.tally.find { |_, count| count > 1 }
      raise ArgumentError, "Account #{duplicate.first} appears more than once in the file" if duplicate

      rows.to_h do |row|
        existing = TudlaAccounting::Account.find_by(organization: organization, code: row[:code])
        if existing
          raise ArgumentError, "Account #{row[:code]} already exists. Enable overwrite mode to reuse existing accounts." unless overwrite_mode

          [ row[:code], existing ]
        else
          category = CATEGORY_MAP[row[:type].downcase]
          raise ArgumentError, "Unknown account type '#{row[:type]}' for account #{row[:code]}; use one of: #{CATEGORY_MAP.keys.join(', ')}" unless category

          [ row[:code], TudlaAccounting::Account.create!(organization: organization, code: row[:code], name: row[:name],
                                                         category: category, currency: organization.currency) ]
        end
      end
    end

    def link_accounts(rows, accounts)
      rows.each do |row|
        account = accounts.fetch(row[:code])
        { parent: :parent_code, contra_account: :contra_code }.each do |association, key|
          next if row[key].blank?

          target = accounts[row[key]]
          raise ArgumentError, "#{association.to_s.humanize} #{row[key]} for account #{row[:code]} is not in the file" unless target

          account.update!(association => target)
        end
      end
    end

    # Opening balances nested the way the file nests the accounts.
    def balance_nodes(rows, accounts)
      children = rows.group_by { |row| row[:parent_code] }
      build = ->(row) do
        { account_id: accounts.fetch(row[:code]).id, amount_cents: row[:amount_cents],
          children: children.fetch(row[:code], []).map(&build) }
      end
      children.fetch(nil, []).map(&build)
    end
  end
end
