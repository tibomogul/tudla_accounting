# frozen_string_literal: true

require "csv"

module TudlaAccounting
  # Loads a chart of accounts and opening balances from a CSV file; see ChartOfAccountsLoader.
  class CsvLoader < ChartOfAccountsLoader
    private

    def read_rows
      CSV.read(file, headers: true, liberal_parsing: true).map(&:to_h)
    end
  end
end
