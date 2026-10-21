# frozen_string_literal: true

require "csv"
require "roo"

module TudlaAccounting
  # The rows of an uploaded CSV or XLSX file (an XLSX's first sheet), as arrays of cells,
  # headings first. Raises ArgumentError for another kind of file or one that can't be
  # read.
  #
  #   SpreadsheetRows.read(upload.path, File.extname(upload.original_filename).downcase)
  module SpreadsheetRows
    module_function

    def read(path, extension)
      case extension
      when ".csv" then CSV.read(path, encoding: "bom|utf-8", liberal_parsing: true)
      when ".xlsx"
        workbook = Roo::Spreadsheet.open(path.to_s, extension: :xlsx)
        sheet = workbook.sheet(workbook.sheets.first)
        (1..sheet.last_row.to_i).map { |index| sheet.row(index) }
      else raise ArgumentError, "Upload a .csv or .xlsx file"
      end
    rescue CSV::MalformedCSVError, Zip::Error, ArgumentError => e
      raise if e.message.start_with?("Upload a")

      raise ArgumentError, "The file can't be read: #{e.message}"
    end
  end
end
