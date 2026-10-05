# frozen_string_literal: true

require "csv"

module TudlaAccounting
  # Imports every open receivable and payable in a CSV file, all or nothing; see
  # CarryingAmountCreator for what each row does. Columns:
  #
  #   particulars, amount, type, due_date, other_currency, other_currency_amount,
  #   transaction_rate, conversion_date
  #
  # Returns the carrying amounts.
  class CarryingAmountsCreator
    def self.call(...)
      new(...).call
    end

    def initialize(organization:, csv_file:, date_prior:, sales_account_code:, purchase_account_code:, source: nil)
      @csv_file = csv_file
      @creator = CarryingAmountCreator.new(organization: organization, date_prior: date_prior, source: source,
                                           sales_account_code: sales_account_code, purchase_account_code: purchase_account_code)
    end

    def call
      rows = CSV.read(@csv_file, headers: true, header_converters: :symbol, skip_blanks: true).map(&:to_h)
      ActiveRecord::Base.transaction { rows.map { |row| @creator.call(row) } }
    end
  end
end
