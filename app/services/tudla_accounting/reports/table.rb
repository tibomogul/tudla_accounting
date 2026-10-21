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
    #
    # to_xlsx (with the caxlsx gem; see TudlaAccounting.xlsx?) writes a workbook of one
    # sheet: amounts as numbers in an accounting format, dates as dates, text always as
    # text (never a formula), the headings and total rows (Table.total) in bold.
    class Table
      FORMULA_START = /\A[=+\-@\t\r]/

      # A row of totals, shown in bold where the format allows.
      class TotalRow < Array; end

      def self.total(cells) = TotalRow.new(cells)

      attr_reader :rows

      def initialize(rows)
        @rows = rows
      end

      def to_csv
        CSV.generate { |csv| rows.each { |row| csv << row.map { |cell| self.class.csv_cell(cell) } } }
      end

      # The workbook's bytes, its sheet named sheet_name (cut to Excel's 31 characters).
      def to_xlsx(sheet_name)
        package = Axlsx::Package.new
        workbook = package.workbook
        styles = xlsx_styles(workbook)
        workbook.add_worksheet(name: sheet_name.tr("[]:*?/\\", " ").first(31)) do |sheet|
          rows.each_with_index do |row, index|
            bold = index.zero? || row.is_a?(TotalRow)
            cells = row.map { |cell| xlsx_cell(cell) }
            sheet.add_row cells.map(&:first), types: cells.map { |cell| cell[1] },
                                              style: cells.map { |cell| styles.fetch([ cell[2], bold ]) }
          end
        end
        package.to_stream.read
      end

      # For the JSON API: the headings, and each row's cells (amounts as plain decimal
      # strings, "-1234.50"; dates as ISO 8601), total rows marked.
      def as_api
        headings, *body = rows
        { headings: headings, rows: body.map { |row| { cells: row.map { |cell| self.class.api_cell(cell) }, total: row.is_a?(TotalRow) } } }
      end

      def self.api_cell(cell)
        cell.is_a?(String) ? cell : csv_cell(cell)
      end

      def self.csv_cell(cell)
        case cell
        when Money then cell.format(symbol: false, thousands_separator: "", decimal_mark: ".")
        when Date, Time, ActiveSupport::TimeWithZone then cell.to_date.iso8601
        when String then cell.match?(FORMULA_START) ? "'#{cell}" : cell
        else cell
        end
      end

      private

      # [value, type, style] for a cell: amounts and other numbers as numbers, dates as
      # dates, anything else as text.
      def xlsx_cell(cell)
        case cell
        when Money then [ cell.to_d, :float, :money ]
        when Integer then [ cell, :integer, :plain ]
        when Numeric then [ cell.to_d, :float, :plain ]
        when Date, Time, ActiveSupport::TimeWithZone then [ cell.to_date, :date, :date ]
        when nil then [ nil, :string, :plain ]
        else [ cell.to_s, :string, :plain ]
        end
      end

      def xlsx_styles(workbook)
        formats = { money: { num_fmt: 4 }, date: { format_code: "yyyy-mm-dd" }, plain: {} } # 4: #,##0.00
        formats.flat_map { |kind, format| [ false, true ].map { |bold| [ [ kind, bold ], workbook.styles.add_style(bold ? format.merge(b: true) : format) ] } }.to_h
      end
    end
  end
end
