# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # The books of accounts, as kept on loose-leaf pages (the BIR's for the Philippines,
    # among others): a general journal, a general ledger, cash receipts and disbursements
    # journals, and sales and purchases journals, over a run of months, each in pages of
    # ROWS_PER_PAGE rows numbered from 1, with each page's totals.
    #
    #   books = BooksOfAccounts.new(organization, from: january, thru: december)
    #   books.book("cash_receipts").pages # => [#<Page number=1 rows=[...] totals={...}>, ...]
    #
    # Each posted entry goes in one journal: one bringing cash in (debiting the cash
    # accounts, those of the cash_account_codes setting, more than it credits them) in cash
    # receipts, one paying cash out in cash disbursements; otherwise a sales invoice or
    # credit note in sales, a bill or supplier credit in purchases, and the rest in the
    # general journal. A columnar journal's lines go to its columns by account and tax code
    # (receivable and payable accounts by role, sales and expenses by category, VAT by the
    # tax lines and, in sales, by the code's treatment), the rest to Other accounts, a row
    # each; an amount on the column's other side (a credit note, tax withheld on a receipt)
    # is negative, so the cash, receivable or payable column always equals the others.
    # The general ledger is Reports::GeneralLedger's, an account a page (or more) with its
    # balance brought forward, debit balances positive and credit ones negative.
    class BooksOfAccounts
      ROWS_PER_PAGE = 30

      # Each book's columns: [key, heading]. Those whose key is in AMOUNTS hold amounts,
      # totalled on each page.
      BOOKS = {
        "general_journal" => { title: "General journal", check: "Check (Debit = Credit):", columns: [
          [ :date, "Date" ], [ :reference, "JV / Reference No." ], [ :particulars, "Particulars\n(Account Title & Explanation)" ], [ :account_code, "Account Code" ],
          [ :debit, "Debit" ], [ :credit, "Credit" ] ] },
        "general_ledger" => { title: "General ledger", columns: [
          [ :date, "Date" ], [ :reference, "Reference\n(Journal / Voucher No.)" ], [ :particulars, "Particulars" ], [ :debit, "Debit" ], [ :credit, "Credit" ],
          [ :balance, "Balance\nDr / (Cr)" ] ] },
        "cash_receipts" => { title: "Cash receipts journal", check: "Check (Cash = sum of credits):", columns: [
          [ :date, "Date" ], [ :reference, "OR / Reference No." ], [ :particulars, "Payor / Particulars" ], [ :cash, "Cash in Bank\n(Debit)" ],
          [ :receivable, "Accounts Receivable\n(Credit)" ], [ :sales, "Sales / Revenue\n(Credit)" ], [ :output_vat, "Output VAT\n(Credit)" ],
          [ :account_title, "Other Accounts\n(Account Title)" ], [ :other, "Other Accounts\n(Credit)" ] ] },
        "cash_disbursements" => { title: "Cash disbursements journal", check: "Check (Cash = sum of debits):", columns: [
          [ :date, "Date" ], [ :reference, "Check / Voucher No." ], [ :particulars, "Payee / Particulars" ], [ :cash, "Cash in Bank\n(Credit)" ],
          [ :payable, "Accounts Payable\n(Debit)" ], [ :expenses, "Expenses\n(Debit)" ], [ :input_vat, "Input VAT\n(Debit)" ],
          [ :account_title, "Other Accounts\n(Account Title)" ], [ :other, "Other Accounts\n(Debit)" ] ] },
        "sales" => { title: "Sales journal", check: "Check (Accounts Receivable = sum of credits):", columns: [
          [ :date, "Date" ], [ :reference, "Invoice No." ], [ :party, "Customer Name" ], [ :tin, "Customer TIN" ], [ :receivable, "Accounts Receivable\n(Debit)" ],
          [ :vatable, "Sales – VATable\n(Credit)" ], [ :zero_rated, "Sales – Zero-Rated\n(Credit)" ], [ :exempt, "Sales – VAT-Exempt\n(Credit)" ],
          [ :output_vat, "Output VAT\n(Credit)" ] ] },
        "purchases" => { title: "Purchase journal", check: "Check (Accounts Payable = sum of debits):", columns: [
          [ :date, "Date" ], [ :reference, "Voucher / Invoice No." ], [ :party, "Supplier Name" ], [ :tin, "Supplier TIN" ], [ :payable, "Accounts Payable\n(Credit)" ],
          [ :purchases, "Purchases / Expenses\n(Debit)" ], [ :input_vat, "Input VAT\n(Debit)" ], [ :account_title, "Other Accounts\n(Account Title)" ],
          [ :other, "Other Accounts\n(Debit)" ] ] }
      }.freeze
      AMOUNTS = %i[debit credit cash receivable payable sales expenses purchases vatable zero_rated exempt output_vat input_vat other].freeze
      # The column each columnar journal's own side is in (debit for receipts and sales);
      # its other amount columns are on the other side.
      ANCHORS = { "cash_receipts" => [ :cash, :debit ], "cash_disbursements" => [ :cash, :credit ], "sales" => [ :receivable, :debit ], "purchases" => [ :payable, :credit ] }.freeze

      # check: what each page's balanced says, for the page.
      Book = Struct.new(:key, :title, :columns, :check, :pages, keyword_init: true) do
        def keys = columns.map(&:first)
      end
      # rows: Row; totals: { column key => Money } for the amount columns; account: the
      # general ledger's account; closing: the ledger's balance at the page's end;
      # balanced: whether the page's debits and credits (or the cash, receivable or
      # payable column and the others) agree.
      Page = Struct.new(:number, :rows, :totals, :account, :closing, :balanced, keyword_init: true)
      # cells: { column key => a date, text or Money }; entry: what it's from; kind: :line,
      # :credit_line (indented in the general journal), :explanation or :brought_forward.
      Row = Struct.new(:cells, :entry, :kind, keyword_init: true)

      attr_reader :organization, :from, :thru

      # from and thru are months (leaf periods); thru is included.
      def initialize(organization, from:, thru:)
        @organization = organization
        @from = from
        @thru = thru
      end

      def books = BOOKS.keys.map { |key| book(key) }

      def book(key)
        definition = BOOKS.fetch(key)
        @books ||= {}
        @books[key] ||= Book.new(key: key, title: definition[:title], columns: definition[:columns], check: definition[:check],
                                 pages: key == "general_ledger" ? ledger_pages : journal_pages(key))
      end

      # The book an entry goes in.
      def book_key(entry)
        cash = entry.details.sum { |detail| cash_ids.include?(detail.account_id) ? signed(detail) : 0 }
        return "cash_receipts" if cash.positive?
        return "cash_disbursements" if cash.negative?

        source = entry.source
        return "general_journal" unless source.is_a?(Document)

        source.sales? ? "sales" : "purchases"
      end

      # "January 1 to December 31, 2027", or with each year when the months span two.
      def period_label
        first, last = from.from_date.to_date, thru.thru_date.to_date
        first.year == last.year ? "#{first.strftime('%B %-d')} to #{last.strftime('%B %-d, %Y')}" : "#{first.strftime('%B %-d, %Y')} to #{last.strftime('%B %-d, %Y')}"
      end

      private

      def journal_pages(key)
        groups = entries.select { |entry| book_key(entry) == key }.map { |entry| key == "general_journal" ? journal_rows(entry) : columnar_rows(key, entry) }
        paginate(groups).each_with_index.map do |rows, index|
          page = Page.new(number: index + 1, rows: rows, totals: totals(key, rows))
          page.balanced = balanced?(key, page.totals)
          page
        end
      end

      # The pages of rows, ROWS_PER_PAGE to a page, each entry's rows kept together unless
      # there are more of them than a page holds.
      def paginate(groups)
        groups.each_with_object([ [] ]) do |rows, pages|
          pages << [] if pages.last.any? && pages.last.size + rows.size > ROWS_PER_PAGE
          rows.each do |row|
            pages << [] if pages.last.size == ROWS_PER_PAGE
            pages.last << row
          end
        end.reject(&:empty?)
      end

      def totals(key, rows)
        (BOOKS.fetch(key)[:columns].map(&:first) & AMOUNTS).index_with { |column| rows.sum(zero) { |row| row.cells[column] || zero } }
      end

      def balanced?(key, totals)
        return totals.fetch(:debit) == totals.fetch(:credit) if key == "general_journal"

        anchor = ANCHORS.fetch(key).first
        totals.fetch(anchor) == totals.except(anchor).values.sum(zero)
      end

      # Debit lines, then credit lines (indented), then the entry's explanation.
      def journal_rows(entry)
        lines = entry.details.sort_by { |detail| [ detail.debit? ? 0 : 1, detail.id ] }
        rows = lines.map do |detail|
          account = accounts.fetch(detail.account_id)
          Row.new(cells: { particulars: account.name, account_code: account.code, (detail.debit? ? :debit : :credit) => money(detail) }, entry: entry,
                  kind: detail.debit? ? :line : :credit_line)
        end
        rows << Row.new(cells: { particulars: "(#{entry.particulars})" }, entry: entry, kind: :explanation) if entry.particulars.present?
        rows.first.cells.merge!(date: date(entry), reference: reference(entry))
        rows
      end

      # One row with the entry's columns, then a row for each further Other account.
      def columnar_rows(key, entry)
        anchor, side = ANCHORS.fetch(key)
        sums = Hash.new(0)
        others = Hash.new(0)
        entry.details.each do |detail|
          column = column_for(key, detail)
          cents = side == :debit ? signed(detail) : -signed(detail)
          cents = -cents unless column == anchor
          column == :other ? others[detail.account_id] += cents : sums[column] += cents
        end
        others = others.reject { |_, cents| cents.zero? }.map { |account_id, cents| { account_title: accounts.fetch(account_id).name, other: Money.new(cents, currency) } }

        cells = sums.reject { |_, cents| cents.zero? }.transform_values { |cents| Money.new(cents, currency) }
        cells.merge!(date: date(entry), **texts(key, entry), **(others.shift || {}))
        [ Row.new(cells: cells, entry: entry, kind: :line), *others.map { |other| Row.new(cells: other, entry: entry, kind: :line) } ]
      end

      # The reference, particulars or party and TIN of an entry in a columnar journal.
      def texts(key, entry)
        source = entry.source
        contact = source.contact if source.respond_to?(:contact)
        case key
        when "sales" then { reference: source.number_label, party: contact.name, tin: contact.tax_number }
        when "purchases" then { reference: source.reference || source.number_label, party: contact.name, tin: contact.tax_number }
        else
          particulars = entry.particulars.to_s
          particulars = "#{contact.name} – #{particulars}" if contact && !particulars.include?(contact.name)
          { reference: reference(entry), particulars: particulars }
        end
      end

      def column_for(key, detail)
        account = accounts.fetch(detail.account_id)
        tax = detail.tax_code if detail.tax_tax?
        send(:"#{key}_column", account, detail, tax)
      end

      def cash_receipts_column(account, _detail, tax)
        return :cash if cash_ids.include?(account.id)
        return :receivable if receivable_ids.include?(account.id)
        return :output_vat if tax&.sales?

        account.income? && !tax ? :sales : :other
      end

      def cash_disbursements_column(account, _detail, tax)
        return :cash if cash_ids.include?(account.id)
        return :payable if payable_ids.include?(account.id)
        return :input_vat if tax&.purchases?

        account.expense? && !tax ? :expenses : :other
      end

      # Sales lines by their tax code's treatment; those without a code are exempt.
      def sales_column(account, detail, tax)
        return :receivable if receivable_ids.include?(account.id)
        return :output_vat if tax
        return :vatable if detail.tax_code&.standard?

        detail.tax_code&.zero_rated? ? :zero_rated : :exempt
      end

      def purchases_column(account, _detail, tax)
        return :payable if payable_ids.include?(account.id)
        return :input_vat if tax

        account.expense? ? :purchases : :other
      end

      # An account a page or more, from Reports::GeneralLedger: each page brings forward
      # the balance before it, debit balances positive.
      def ledger_pages
        number = 0
        GeneralLedger.new(organization, from: from, thru: thru).accounts.flat_map do |section|
          account = section.account
          balance = account.debit_balance? ? section.opening : -section.opening
          slices = section.lines.each_slice(ROWS_PER_PAGE - 1).to_a.presence || [ [] ]
          slices.each_with_index.map do |lines, index|
            brought = Row.new(cells: { date: (from.from_date.to_date if index.zero?), particulars: "Balance brought forward", balance: balance }, kind: :brought_forward)
            rows = [ brought ] + lines.map do |line|
              balance += (line.debit || zero) - (line.credit || zero)
              Row.new(cells: { date: line.date.to_date, reference: reference(line.entry), particulars: line.detail.description || line.entry.particulars,
                               debit: line.debit, credit: line.credit, balance: balance }.compact, entry: line.entry, kind: :line)
            end
            totals = { debit: lines.sum(zero) { |line| line.debit || zero }, credit: lines.sum(zero) { |line| line.credit || zero } }
            Page.new(number: number += 1, rows: rows, totals: totals, account: account, closing: balance, balanced: true)
          end
        end
      end

      def entries
        @entries ||= begin
          list = Entry.where(organization: organization, posted_at: from.from_date..thru.thru_date).includes(:details, :source).order(:posted_at, :id).to_a
          sources = list.map(&:source).select { |source| source.respond_to?(:contact) }
          ActiveRecord::Associations::Preloader.new(records: sources, associations: :contact).call if sources.any?
          ActiveRecord::Associations::Preloader.new(records: list.flat_map(&:details), associations: :tax_code).call
          list
        end
      end

      def accounts
        @accounts ||= Account.where(organization: organization).index_by(&:id)
      end

      # The cash accounts (those of the cash_account_codes setting) and those beneath them.
      def cash_ids
        @cash_ids ||= subtree_ids(accounts.values.select { |account| TudlaAccounting.configuration.cash_account_codes_for(organization).include?(account.code) })
      end

      def receivable_ids = @receivable_ids ||= subtree_ids(accounts.values.select(&:role_receivable?))
      def payable_ids = @payable_ids ||= subtree_ids(accounts.values.select(&:role_payable?))

      def subtree_ids(chosen)
        ids = chosen.map(&:id).to_set
        accounts.values.select { |account| ids.include?(account.id) || account.ancestor_ids.any? { |id| ids.include?(id) } }.map(&:id).to_set
      end

      def reference(entry) = entry.reference || entry.number_label
      def date(entry) = entry.posted_at.to_date
      def signed(detail) = detail.debit? ? detail.amount_cents : -detail.amount_cents
      def money(detail) = Money.new(detail.amount_cents, currency)
      def currency = organization.currency
      def zero = Money.new(0, currency)
    end
  end
end
