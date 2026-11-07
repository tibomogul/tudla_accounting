# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # The books of accounts with made-up rows and no postings: a page of each book in the
    # same layout, as a sample of their format for a tax office (the BIR asks for one with
    # the application to use loose-leaf books). A new organization, with no financial year
    # yet, can print it. It goes wherever BooksOfAccounts does (the book page, PdfMaker.book,
    # BooksWorkbook).
    #
    #   SampleBooks.new(organization, year: 2027).book("sales").pages
    class SampleBooks < BooksOfAccounts
      LedgerAccount = Struct.new(:name, :code, keyword_init: true)
      CLIENT = "Sample Client Inc."
      SUPPLIER = "Sample Supplier Corp."
      SAMPLE_TIN = "000-000-000-000"

      attr_reader :year

      def initialize(organization, year:)
        super(organization, from: nil, thru: nil)
        @year = year
      end

      def sample? = true

      def period_label = "January 1 to December 31, #{year}"

      private

      def journal_pages(key)
        rows = send(:"#{key}_samples").map { |kind, cells| Row.new(cells: cells, kind: kind) }
        page_totals = totals(key, rows)
        [ Page.new(number: 1, rows: rows, totals: page_totals, balanced: balanced?(key, page_totals)) ]
      end

      def ledger_pages
        rows = [
          Row.new(cells: { date: on(1, 1), particulars: "Balance brought forward", balance: amount(0) }, kind: :brought_forward),
          Row.new(cells: { date: on(1, 15), reference: "OR-0001", particulars: "#{CLIENT} – payment of Inv. 1001", debit: amount(100_000), balance: amount(100_000) }, kind: :line),
          Row.new(cells: { date: on(1, 20), reference: "CV-0001", particulars: "#{SUPPLIER} – Inv. S-555 (office supplies)", credit: amount(11_200), balance: amount(88_800) }, kind: :line),
          Row.new(cells: { date: on(1, 31), reference: "JV-#{year}-001", particulars: "Sample: January rent", credit: amount(25_000), balance: amount(63_800) }, kind: :line)
        ]
        [ Page.new(number: 1, rows: rows, totals: { debit: amount(100_000), credit: amount(36_200) }, account: LedgerAccount.new(name: "Cash in Bank", code: "1010"),
                   closing: amount(63_800), balanced: true) ]
      end

      def general_journal_samples
        [ [ :line, { date: on(1, 31), reference: "JV-#{year}-001", particulars: "Rent expense", account_code: "6100", debit: amount(25_000) } ],
          [ :credit_line, { particulars: "Cash in Bank", account_code: "1010", credit: amount(25_000) } ],
          [ :explanation, { particulars: "(Sample: to record January rent)" } ] ]
      end

      def cash_receipts_samples
        [ [ :line, { date: on(1, 15), reference: "OR-0001", particulars: "#{CLIENT} – payment of Inv. 1001", cash: amount(100_000), receivable: amount(100_000) } ],
          [ :line, { date: on(1, 16), reference: "OR-0002", particulars: "#{CLIENT} – cash sale", cash: amount(11_200), sales: amount(10_000), output_vat: amount(1_200) } ],
          [ :line, { date: on(1, 17), reference: "OR-0003", particulars: "#{CLIENT} – fee, tax withheld", cash: amount(980), sales: amount(1_000),
                     account_title: "Creditable withholding tax", other: amount(-20) } ] ]
      end

      def cash_disbursements_samples
        [ [ :line, { date: on(1, 20), reference: "CV-0001", particulars: "#{SUPPLIER} – Inv. S-555 (office supplies)", cash: amount(11_200), expenses: amount(10_000), input_vat: amount(1_200) } ],
          [ :line, { date: on(1, 21), reference: "CV-0002", particulars: "#{SUPPLIER} – payment on account", cash: amount(5_000), payable: amount(5_000) } ],
          [ :line, { date: on(1, 22), reference: "CV-0003", particulars: "#{SUPPLIER} – laptop", cash: amount(50_000), account_title: "Equipment", other: amount(50_000) } ] ]
      end

      def sales_samples
        [ [ :line, { date: on(1, 10), reference: "SI-1001", party: CLIENT, tin: SAMPLE_TIN, receivable: amount(100_000), zero_rated: amount(100_000) } ],
          [ :line, { date: on(1, 11), reference: "SI-1002", party: CLIENT, tin: SAMPLE_TIN, receivable: amount(11_200), vatable: amount(10_000), output_vat: amount(1_200) } ],
          [ :line, { date: on(1, 12), reference: "SI-1003", party: CLIENT, tin: SAMPLE_TIN, receivable: amount(5_000), exempt: amount(5_000) } ] ]
      end

      def purchases_samples
        [ [ :line, { date: on(1, 18), reference: "S-555", party: SUPPLIER, tin: SAMPLE_TIN, payable: amount(11_200), purchases: amount(10_000), input_vat: amount(1_200) } ],
          [ :line, { date: on(1, 19), reference: "S-556", party: SUPPLIER, tin: SAMPLE_TIN, payable: amount(56_000), input_vat: amount(6_000), account_title: "Equipment", other: amount(50_000) } ] ]
      end

      def on(month, day) = Date.new(year, month, day)
      def amount(whole) = TudlaAccounting.money(whole, currency)
    end
  end
end
