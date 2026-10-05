# frozen_string_literal: true

require "roo"

module TudlaAccounting
  # Loads a chart of accounts and opening balances from an XLSX file, reading the sheet
  # named "Accounts" (or the first sheet); see ChartOfAccountsLoader.
  class XlsxLoader < ChartOfAccountsLoader
    private

    def read_rows
      workbook = Roo::Spreadsheet.open(file.to_s, extension: :xlsx)
      sheet = workbook.sheet(workbook.sheets.include?("Accounts") ? "Accounts" : workbook.sheets.first)
      headers = sheet.row(1).map { |header| header.to_s.strip }
      (2..sheet.last_row.to_i).map { |index| headers.zip(sheet.row(index)).to_h }
    end
  end
end
