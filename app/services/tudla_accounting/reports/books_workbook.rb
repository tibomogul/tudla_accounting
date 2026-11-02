# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # The books of accounts (BooksOfAccounts) as an Excel workbook to print and bind (with
    # the caxlsx gem; see TudlaAccounting.xlsx?): a cover sheet listing each book and its
    # number of pages (for the sworn statement that goes with them), then a sheet a book, in
    # the layout of the commonly used loose-leaf templates. Each page is a block of the
    # books_header, the book's title, the period (or the ledger's account), the page
    # number, the column headings, ROWS_PER_PAGE rows (blank ones filling a short page), a
    # TOTAL row and the check, with a page break after it, scaled to print on one A4
    # sheet: landscape for the journals, portrait for the ledger, as in the templates.
    #
    # Amounts are numbers in the currency's decimal places, negative ones in parentheses,
    # zero as "-"; dates are dates; text is always text, never a formula.
    #
    #   BooksWorkbook.new(books).to_xlsx # => the workbook's bytes
    class BooksWorkbook
      SHEETS = {
        "general_journal" => "GeneralJournal", "general_ledger" => "GeneralLedger", "cash_receipts" => "CashReceiptsJournal",
        "cash_disbursements" => "CashDisbursementsJournal", "sales" => "SalesJournal", "purchases" => "PurchaseJournal"
      }.freeze
      # Each book's column widths, in characters, as in the templates.
      WIDTHS = {
        "general_journal" => [ 13, 20, 52, 14, 18, 18 ], "general_ledger" => [ 13, 18, 46, 17, 17, 20 ],
        "cash_receipts" => [ 13, 18, 42, 17, 17, 17, 15, 26, 16 ], "cash_disbursements" => [ 13, 18, 42, 17, 17, 17, 15, 26, 16 ],
        "sales" => [ 13, 16, 36, 18, 18, 17, 17, 17, 15 ], "purchases" => [ 13, 18, 36, 18, 18, 18, 15, 26, 16 ]
      }.freeze
      # A4 in points, and the margins in inches.
      PAPER = { portrait: [ 595, 842 ], landscape: [ 842, 595 ] }.freeze
      MARGINS = { left: 0.5, right: 0.5, top: 0.6, bottom: 0.6, header: 0.3, footer: 0.3 }.freeze
      # Row heights in points.
      HEIGHTS = { name: 16, line: 13.5, title: 16, period: 13.5, gap: 6, headings: 42, row: 13.5 }.freeze
      FONT = { font_name: "Arial", sz: 10 }.freeze
      BORDER = { style: :thin, color: "FF000000" }.freeze

      attr_reader :books

      def initialize(books)
        @books = books
      end

      def to_xlsx
        package = Axlsx::Package.new
        @workbook = package.workbook
        @styles = {}
        @workbook.styles.fonts.first.tap { |font| font.name = FONT[:font_name] }.sz = FONT[:sz] # column widths are in its digits
        add_cover
        books.books.each { |book| add_book(book) }
        package.to_stream.read
      end

      private

      def header_lines = @header_lines ||= TudlaAccounting.configuration.books_header_for(books.organization).lines.map(&:chomp).reject(&:blank?)

      def add_cover
        @workbook.add_worksheet(name: "Cover", page_setup: { paper_size: 9, orientation: :portrait }, page_margins: MARGINS) do |sheet|
          header_lines.each_with_index { |line, index| sheet.add_row [ line ], style: style(index.zero? ? :name : :line), types: [ :string ] }
          sheet.add_row [ books.sample? ? "BOOKS OF ACCOUNTS – SAMPLE FORMAT" : "BOOKS OF ACCOUNTS" ], style: style(:title), types: [ :string ]
          sheet.add_row [ "For the period: #{books.period_label}" ], style: style(:line), types: [ :string ]
          sheet.add_row []
          sheet.add_row [ "Book", "Sheet", "Pages" ], style: style(:heading), height: 20
          books.books.each { |book| sheet.add_row [ book.title, SHEETS.fetch(book.key), book.pages.size ], style: [ style(:text), style(:text), style(:count) ], types: %i[string string integer] }
          sheet.add_row [ "Total pages", nil, books.books.sum { |book| book.pages.size } ], style: [ style(:total_label), style(:total_label), style(:total_count) ], types: %i[string string integer]
          sheet.add_row []
          sheet.add_row [ "Each page prints on a sheet of its own, numbered from 1 in each book, #{BooksOfAccounts::ROWS_PER_PAGE} rows to a page." ], style: style(:note), types: [ :string ]
          sheet.add_row [ "A sample of each book's format: the rows are examples, not postings." ], style: style(:note), types: [ :string ] if books.sample?
          (header_lines.size + 2).times { |index| sheet.merge_cells("A#{index + 1}:C#{index + 1}") }
          sheet.column_widths 36, 28, 12
        end
      end

      def add_book(book)
        widths = WIDTHS.fetch(book.key)
        orientation = book.key == "general_ledger" ? :portrait : :landscape
        @workbook.add_worksheet(name: SHEETS.fetch(book.key), page_margins: MARGINS, print_options: { horizontal_centered: true }) do |sheet|
          if book.pages.empty?
            page_header(sheet, book, nil)
            sheet.add_row [ "Nothing in the #{book.title.downcase} for these months." ], style: style(:note), types: [ :string ]
          else
            book.pages.each_with_index do |page, index|
              sheet.add_page_break("A#{sheet.rows.size + 1}") if index.positive?
              add_page(sheet, book, page)
            end
          end
          sheet.column_widths(*widths)
          sheet.page_setup.set(paper_size: 9, orientation: orientation, scale: scale(widths, orientation))
        end
      end

      def add_page(sheet, book, page)
        page_header(sheet, book, page)
        page.rows.each { |row| add_cells(sheet, book, row.cells, row.kind) }
        (BooksOfAccounts::ROWS_PER_PAGE - page.rows.size).times { add_cells(sheet, book, {}, :line) }
        totals = page.totals.merge(book.key == "general_ledger" ? { balance: page.closing } : {})
        label = label_key(book)
        sheet.add_row(book.keys.map { |key| key == label ? "TOTAL" : totals[key]&.to_d },
                      style: book.keys.map { |key| totals.key?(key) ? style(:total_money, totals[key].currency.exponent) : style(:total_label) },
                      types: book.keys.map { |key| totals.key?(key) ? :float : :string }, height: HEIGHTS[:row])
        return unless book.check

        result_at = book.keys.index { |key| BooksOfAccounts::AMOUNTS.include?(key) }
        sheet.add_row(book.keys.each_index.map { |index| { book.keys.index(label) => book.check, result_at => page.balanced ? "Balanced" : "OUT OF BALANCE" }[index] },
                      style: style(:check), types: :string, height: HEIGHTS[:row])
      end

      # The books_header, the book's title, the period (or the ledger's account) and the
      # page number, and the column headings.
      def page_header(sheet, book, page)
        last = book.columns.size
        header_lines.each_with_index { |line, index| merged_row(sheet, last, line, index.zero? ? :name : :line) }
        merged_row(sheet, last, book.title.upcase, :title)
        page_number = "Page No.: #{page&.number}"
        if book.key == "general_ledger"
          account = page&.account
          sheet.add_row [ "Account Title:", account&.name, nil, "Account Code:", account&.code, page_number ],
                        style: [ style(:label), style(:strong), style(:strong), style(:label), style(:strong), style(:page_number) ], types: :string, height: HEIGHTS[:period]
          sheet.merge_cells("B#{sheet.rows.size}:C#{sheet.rows.size}")
        else
          sheet.add_row [ "For the period: #{books.period_label}", *Array.new(last - 2), page_number ],
                        style: [ *Array.new(last - 1, style(:text_plain)), style(:page_number) ], types: :string, height: HEIGHTS[:period]
          sheet.merge_cells("A#{sheet.rows.size}:#{column(last - 1)}#{sheet.rows.size}")
        end
        sheet.add_row [], height: HEIGHTS[:gap]
        sheet.add_row book.columns.map(&:last), style: style(:heading), types: :string, height: HEIGHTS[:headings]
      end

      def merged_row(sheet, last, text, kind)
        sheet.add_row [ text ], style: style(kind), types: [ :string ], height: HEIGHTS[kind]
        sheet.merge_cells("A#{sheet.rows.size}:#{column(last)}#{sheet.rows.size}")
      end

      def add_cells(sheet, book, cells, kind)
        values = book.keys.map do |key|
          value = cells[key]
          case value
          when Money then [ value.to_d, :float, style(:money, value.currency.exponent) ]
          when Date then [ value, :date, style(:date) ]
          else [ value&.to_s, :string, style(cell_kind(key, kind)) ]
          end
        end
        sheet.add_row values.map(&:first), types: values.map { |value| value[1] }, style: values.map(&:last), height: HEIGHTS[:row]
      end

      def cell_kind(key, kind)
        return :indented if key == :particulars && kind == :credit_line
        return :explanation if kind == :explanation
        return :money_blank if BooksOfAccounts::AMOUNTS.include?(key) || key == :balance

        :cell
      end

      # Where a page's TOTAL and check go: the particulars or party column.
      def label_key(book) = (book.keys & %i[particulars party]).first

      def column(number) = Axlsx.col_ref(number - 1)

      # The print scale (in percent) at which a page's block fits on one sheet, with a
      # little to spare for the spreadsheet's own rounding.
      def scale(widths, orientation)
        paper_width, paper_height = PAPER.fetch(orientation)
        usable_width = paper_width - (MARGINS[:left] + MARGINS[:right]) * 72
        usable_height = paper_height - (MARGINS[:top] + MARGINS[:bottom]) * 72
        width = widths.sum { |characters| (characters * 7 + 5) * 0.75 }
        height = block_height
        ([ usable_width / width, usable_height / height, 1 ].min * 97).floor.clamp(10, 100)
      end

      def block_height
        HEIGHTS[:name] + (header_lines.size - 1).clamp(0..) * HEIGHTS[:line] + HEIGHTS.values_at(:title, :period, :gap, :headings).sum +
          (BooksOfAccounts::ROWS_PER_PAGE + 2) * HEIGHTS[:row]
      end

      def style(kind, places = nil)
        @styles[[ kind, places ]] ||= @workbook.styles.add_style(FONT.merge(STYLES.fetch(kind)).merge(places ? { format_code: money_format(places) } : {}))
      end

      def money_format(places)
        number = places.zero? ? "#,##0" : "#,##0.#{'0' * places}"
        "#{number};(#{number});-"
      end

      CENTER = { horizontal: :center, vertical: :center }.freeze
      STYLES = {
        name: { b: true, sz: 12, alignment: CENTER }, line: { alignment: CENTER }, title: { b: true, sz: 12, alignment: CENTER },
        text_plain: {}, label: {}, strong: { b: true }, page_number: { alignment: { horizontal: :right } },
        heading: { b: true, bg_color: "FFD9D9D9", border: BORDER, alignment: CENTER.merge(wrap_text: true) },
        cell: { border: BORDER }, indented: { border: BORDER, alignment: { indent: 2 } }, explanation: { i: true, border: BORDER },
        date: { border: BORDER, format_code: "mm/dd/yyyy", alignment: { horizontal: :center } }, money: { border: BORDER }, money_blank: { border: BORDER },
        total_label: { b: true, alignment: { horizontal: :right }, border: { style: :thin, color: "FF000000", edges: %i[top bottom] } },
        total_money: { b: true, border: { style: :thin, color: "FF000000", edges: %i[top bottom] } },
        check: { b: true, alignment: { horizontal: :right } },
        text: { border: BORDER }, count: { border: BORDER }, total_count: { b: true, border: BORDER }, note: { i: true }
      }.freeze
    end
  end
end
