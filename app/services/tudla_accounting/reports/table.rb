# frozen_string_literal: true

require "csv"

module TudlaAccounting
  module Reports
    # A report laid out for exporting: rows of plain cells, the first row its headings.
    # Cells are text, numbers, Money, dates or nil; to_csv writes amounts as plain numbers
    # ("-1234.50") and dates as ISO 8601.
    #
    # Text that a spreadsheet would read as a formula (starting with =, +, -, @, a tab or a
    # carriage return: an account name, a party's name, an entry's particulars) is written
    # with a leading apostrophe, so opening the file never runs it.
    class Table
      FORMULA_START = /\A[=+\-@\t\r]/

      attr_reader :rows

      def initialize(rows)
        @rows = rows
      end

      def to_csv
        CSV.generate { |csv| rows.each { |row| csv << row.map { |cell| self.class.csv_cell(cell) } } }
      end

      def self.csv_cell(cell)
        case cell
        when Money then cell.format(symbol: false, thousands_separator: "", decimal_mark: ".")
        when Date, Time, ActiveSupport::TimeWithZone then cell.to_date.iso8601
        when String then cell.match?(FORMULA_START) ? "'#{cell}" : cell
        else cell
        end
      end
    end
  end
end
