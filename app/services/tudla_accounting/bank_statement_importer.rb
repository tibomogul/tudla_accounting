# frozen_string_literal: true

require "csv"
require "digest"

module TudlaAccounting
  # Imports a bank statement CSV for a bank account:
  #
  #   BankStatementImporter.call(account, "statement.csv", date_order: :dmy)
  #   # => { imported: 42, skipped: 3 }
  #
  # Columns are found by their headers (any case): a date ("Date", "Transaction date"); a
  # description ("Description", "Details", "Narrative", "Payee", "Memo"); either one
  # signed "Amount" or separate money in and out columns ("Credit"/"Deposit"/"Money in"
  # and "Debit"/"Withdrawal"/"Money out"); and optionally "Reference", "Balance" and an
  # "Id" the bank gives each transaction. Dates are ISO (2026-03-01) or, by date_order,
  # day/month/year or month/day/year. Amounts may carry commas, a currency symbol, or
  # parentheses for money out.
  #
  # Importing the same transactions again skips them: each line is known by the bank's id
  # or, without one, by its date, description, amount, reference and balance (and how
  # many identical lines came before it in the file).
  class BankStatementImporter
    HEADERS = {
      date: [ "date", "transaction date", "posted date", "posting date" ],
      description: [ "description", "details", "narrative", "payee", "memo", "transaction details" ],
      amount: [ "amount" ],
      money_in: [ "credit", "deposit", "deposits", "money in", "paid in", "credit amount" ],
      money_out: [ "debit", "withdrawal", "withdrawals", "money out", "paid out", "debit amount" ],
      reference: [ "reference", "ref", "cheque number", "check number" ],
      balance: [ "balance", "running balance" ],
      id: [ "id", "transaction id", "fitid" ]
    }.freeze
    DATE_FORMATS = { dmy: "%d/%m/%Y", mdy: "%m/%d/%Y" }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(account, path, date_order: :dmy)
      @account = account
      @path = path
      @date_format = DATE_FORMATS.fetch(date_order.to_sym) { raise ArgumentError, "date_order must be :dmy or :mdy" }
      @currency = account.currency.presence || account.organization.currency
    end

    def call
      rows = CSV.read(@path, headers: true, skip_blanks: true)
      columns = find_columns(rows.headers)
      seen = Hash.new(0)
      lines = rows.each_with_index.filter_map do |row, index|
        next if row.fields.all?(&:blank?)

        line_from(row, columns, index + 2, seen)
      end

      ActiveRecord::Base.transaction do
        existing = BankStatementLine.where(account: @account, external_id: lines.map { |line| line[:external_id] }).pluck(:external_id).to_set
        fresh = lines.reject { |line| existing.include?(line[:external_id]) }
        fresh.each { |line| BankStatementLine.create!(line.merge(organization: @account.organization, account: @account, currency: @currency)) }
        result = { imported: fresh.size, skipped: lines.size - fresh.size }
        AuditEvent.record!("bank_statement.imported", organization: @account.organization, subject: @account, details: result)
        result
      end
    end

    private

    def find_columns(headers)
      names = headers.compact.index_by { |header| header.to_s.strip.downcase }
      columns = HEADERS.transform_values { |options| options.filter_map { |option| names[option] }.first }
      raise ArgumentError, "The file needs a Date column" unless columns[:date]
      raise ArgumentError, "The file needs a Description column" unless columns[:description]
      raise ArgumentError, "The file needs an Amount column, or money in and money out columns" unless columns[:amount] || (columns[:money_in] && columns[:money_out])

      columns
    end

    def line_from(row, columns, number, seen)
      amount = if columns[:amount]
        cents(row[columns[:amount]], number)
      else
        cents(row[columns[:money_in]], number).to_i - cents(row[columns[:money_out]], number).to_i.abs
      end
      raise ArgumentError, "Row #{number} has no amount" if amount.nil? || amount.zero?

      line = { occurred_on: date(row[columns[:date]], number), description: row[columns[:description]].to_s.strip.presence || "(no description)",
               reference: columns[:reference] && row[columns[:reference]].to_s.strip.presence, amount_cents: amount,
               balance_cents: columns[:balance] && cents(row[columns[:balance]], number) }
      line.merge(external_id: external_id(row, columns, line, seen))
    end

    def external_id(row, columns, line, seen)
      bank_id = columns[:id] && row[columns[:id]].to_s.strip.presence
      return "id:#{bank_id}" if bank_id

      key = line.values_at(:occurred_on, :description, :amount_cents, :reference, :balance_cents).join("|")
      "row:#{Digest::SHA256.hexdigest("#{key}|#{seen[key] += 1}")[0, 32]}"
    end

    def date(text, number)
      text = text.to_s.strip
      text.match?(/\A\d{4}-\d{2}-\d{2}/) ? Date.iso8601(text[0, 10]) : Date.strptime(text, @date_format)
    rescue Date::Error
      raise ArgumentError, "Row #{number} has a date that can't be read: #{text}"
    end

    def cents(text, number)
      text = text.to_s.strip
      return nil if text.empty?

      negative = text.start_with?("(") && text.end_with?(")") || text.start_with?("-") || text.end_with?("-")
      digits = text.delete("^0-9.")
      raise ArgumentError, "Row #{number} has an amount that can't be read: #{text}" if digits.empty?

      value = Money.from_amount(BigDecimal(digits), @currency).cents
      negative ? -value : value
    end
  end
end
