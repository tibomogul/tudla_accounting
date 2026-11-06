# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # Each report as a Table, for exporting, with what the pages show. The callers name
    # periods and parties (labels: and party_name:), as the pages do.
    module Tables
      module_function

      # A balance sheet or profit and loss (a Comparison, of one period or several): a row
      # per account, with its section, code and level in the account tree, then the
      # section's total; the figures after the sections. With change, the columns go in
      # pairs, each followed by the change from its second to its first and as a percentage
      # of the second (blank when it is zero), headed by change_headings, a pair for each.
      def statement(comparison, labels:, sections:, figures:, change: false, change_headings: [ [ "Change", "Change %" ] ])
        headings = [ "Section", "Code", "Account", "Level", *(change ? labels.each_slice(2).zip(change_headings).flat_map { |pair, extra| [ *pair, *extra ] } : labels) ]
        amounts = ->(values) { change ? values.each_slice(2).flat_map { |pair| [ *pair, pair[0] - pair[1], percent(pair) ] } : values }
        rows = sections.flat_map do |category, total_label|
          title = ReportsHelper::SECTION_TITLES.fetch(category)
          [ *comparison.rows(category).map { |row| [ title, row.account.code, row.account.name, row.depth, *amounts.call(row.amounts) ] },
            Table.total([ title, nil, total_label || "Total #{title.downcase}", nil, *amounts.call(comparison.total(category)) ]) ]
        end
        rows += figures.map { |figure, label| Table.total([ nil, nil, label, nil, *amounts.call(comparison.values(figure)) ]) }
        Table.new([ headings, *rows ])
      end

      def trial_balance(report)
        rows = report.rows.map { |row| [ row.account.code, row.account.name, row.debit, row.credit ] }
        Table.new([ [ "Code", "Account", "Debit", "Credit" ], *rows, Table.total([ nil, "Total", report.total_debits, report.total_credits ]) ])
      end

      # A row per open item (credits to apply as negative amounts), its amount in the
      # column of its bucket, then the totals.
      def aging(report, party_name:)
        buckets = AgingReportGenerator::BUCKETS
        headings = [ "Party", "Entry no.", "Entry", "Due", "Days overdue", *buckets.map { |bucket| ReportsHelper::AGING_BUCKETS.fetch(bucket) }, "Total" ]
        rows = report[:details].flat_map do |key, lines|
          party = party_name.call(report[:summary].fetch(key)[:related_party])
          lines.map do |line|
            entry = line[:entry]
            [ party, entry.number_label, entry.particulars, (line[:carrying_amount].due_date unless line[:credit]),
              (line[:days_outstanding] if line[:days_outstanding].positive?),
              *buckets.map { |bucket| line[:outstanding] if line[:aging_bucket] == bucket }, line[:outstanding] ]
          end
        end
        Table.new([ headings, *rows, Table.total([ "Total", nil, nil, nil, nil, *buckets.map { |bucket| report[:totals][bucket] }, report[:totals][:total] ]) ])
      end

      def tax(report)
        rows = report[:codes].map do |row|
          code = row[:tax_code]
          [ code.code, code.name, code.kind.capitalize, code.rate * 100, row[:base], row[:tax] ]
        end
        Table.new([ [ "Code", "Name", "Kind", "Rate %", "Taxed amount", "Tax" ], *rows,
                    Table.total([ nil, "Total sales", nil, nil, report[:sales][:base], report[:sales][:tax] ]),
                    Table.total([ nil, "Total purchases", nil, nil, report[:purchases][:base], report[:purchases][:tax] ]),
                    Table.total([ nil, report[:net_tax].negative? ? "Net tax refundable" : "Net tax payable", nil, nil, nil, report[:net_tax] ]) ])
      end

      # A section a side: a row per code with its months, then the total and the accounts'
      # movement.
      def withholding_summary(report)
        months = report.months
        blanks = Array.new(months.size)
        rows = { "from_supplier" => "Withheld from suppliers", "by_customer" => "Withheld by customers" }.flat_map do |direction, section|
          summary = report.summary(direction)
          checks = report.checks(direction).flat_map do |check|
            [ [ section, check.account.code, "#{check.account.name}: account's movement", nil, *blanks, nil, check.movement ],
              [ section, check.account.code, "#{check.account.name}: difference", nil, *blanks, nil, check.difference ] ]
          end
          [ *summary.map { |row| [ section, row.code.code, row.code.name, row.code.rate * 100, *row.months, row.base, row.withheld ] },
            Table.total([ section, nil, "Total", nil, *report.month_totals(direction), summary.sum(Money.new(0, report.organization.currency), &:base), report.total(direction) ]), *checks ]
        end
        Table.new([ [ "Section", "Code", "Name", "Rate %", *months.map { |month| month.strftime("%b %Y") }, "Income", "Tax withheld" ], *rows ])
      end

      def qap(report) = withholding_list(report.qap, report, "Payee")

      # What the list leaves out follows its total.
      def sawt(report)
        table = withholding_list(report.sawt, report, "Withholding agent")
        Table.new([ *table.rows, [ nil, nil, "Not listed: waiting for a certificate", nil, nil, nil, report.waiting, nil ], [ nil, nil, "Not listed: since reversed", nil, nil, nil, report.reversed, nil ] ])
      end

      def withholding_list(rows, report, who)
        zero = Money.new(0, report.organization.currency)
        body = rows.each_with_index.map do |row, index|
          [ index + 1, row.contact.tax_number, row.contact.name, row.code.code, row.code.rate * 100, row.base, row.withheld, ("No TIN" if row.contact.tax_number.blank?) ]
        end
        Table.new([ [ "No.", "TIN", who, "Code", "Rate %", "Income", "Tax withheld", "Note" ], *body, Table.total([ nil, nil, "Total", nil, nil, rows.sum(zero, &:base), rows.sum(zero, &:withheld), nil ]) ])
      end

      # A row per payee, with what the year-end report needs: name and address, the gross
      # payment and the tax withheld.
      def payee_payments(report)
        body = report.payees.each_with_index.map do |payee, index|
          contact = payee.contact
          [ index + 1, contact.name, contact.address, contact.postal_code, payee.codes.map(&:code).join(", "), payee.gross, payee.withheld, ("No address" if payee.missing_address?) ]
        end
        Table.new([ [ "No.", "Payee", "Address", "Postal code", "Code", "Gross payment", "Tax withheld", "Note" ], *body,
                    Table.total([ nil, "Total", nil, nil, nil, report.total_gross, report.total_withheld, nil ]) ])
      end

      # A row per payee, with what a taxable payments report asks for: its ABN (tax number),
      # name and address, and the gross paid, the GST in it and the tax withheld.
      def taxable_payments(report)
        body = report.payees.each_with_index.map do |payee, index|
          contact = payee.contact
          notes = [ ("No ABN" if payee.missing_tax_number?), ("No address" if payee.missing_address?), ("#{AmountParser.text(payee.unapplied)} paid on no bill, so no GST" unless payee.unapplied.zero?) ].compact
          [ index + 1, contact.tax_number, contact.name, contact.address, contact.postal_code, contact.phone, payee.gross, payee.gst, payee.withheld, notes.join("; ").presence ]
        end
        Table.new([ [ "No.", "ABN", "Payee", "Address", "Postal code", "Phone", "Gross paid", "GST", "Tax withheld", "Note" ], *body,
                    Table.total([ nil, nil, "Total", nil, nil, nil, report.total(:gross), report.total(:gst), report.total(:withheld), nil ]) ])
      end

      # A row per contact per month, then the total and any difference from the tax summary.
      # Final VAT withheld and non-creditable input tax aren't recorded, so stay at zero.
      def summary_list(report, side)
        sales = side == :sales
        totals = report.total(side)
        zero = Money.new(0, report.organization.currency)
        bases = sales ? %i[exempt zero_rated taxable] : %i[exempt zero_rated services capital_goods other_goods]
        bases += [ :not_set ] unless totals[:not_set].zero?
        labels = { exempt: "Exempt", zero_rated: "Zero-rated", taxable: "VATable (before VAT)", services: "Services", capital_goods: "Capital goods", other_goods: "Other goods", not_set: "Not set" }
        lay_out = ->(who, amounts, tax, total, note) do
          [ *who, *amounts, zero, tax, *([ zero ] unless sales), total, note ]
        end
        body = report.rows_for(side).map do |row|
          contact = row.contact
          no_tin = contact && contact.tax_number.blank? && (!sales || !row.taxable.zero?)
          who = [ row.month.strftime("%b %Y"), contact&.tax_number, contact ? contact.name : "No contact", *([ contact&.full_address.to_s.squish.presence ] unless sales) ]
          lay_out.call(who, bases.map { |name| row.public_send(name) }, row.tax, row.total, ("No TIN" if no_tin))
        end
        label = ->(text) { [ nil, nil, text, *([ nil ] unless sales) ] }
        total = lay_out.call(label.call("Total"), bases.map { |name| totals[name] }, totals[:tax], report.rows_for(side).sum(zero, &:total), nil)
        difference = report.difference(side)
        check = lay_out.call(label.call("Difference from the tax summary"), bases.map { nil }, difference.tax, difference.base, nil)
        Table.new([ [ "Month", "TIN", sales ? "Buyer" : "Seller", *("Address" unless sales), *bases.map { |name| labels.fetch(name) }, "Final VAT withheld", sales ? "Output tax" : "Creditable input tax",
                      *("Non-creditable input tax" unless sales), sales ? "Total sales" : "Total purchases", "Note" ], *body, Table.total(total), check ])
      end

      # A column per dimension value ("Untagged" for lines without one), then the total.
      def by_dimension(report)
        columns = report[:columns]
        headings = [ "Section", "Code", "Account", *columns.map { |value| value ? value.name : "Untagged" }, "Total" ]
        rows = %i[income expense].flat_map do |section|
          title = ReportsHelper::SECTION_TITLES.fetch(section.to_s)
          totals = report[:totals][section]
          [ *report[section].map { |row| [ title, row[:account].code, row[:account].name, *columns.map { |column| row[:amounts][column] }, row[:total] ] },
            Table.total([ title, nil, "Total #{title.downcase}", *columns.map { |column| totals[column] }, totals[:total] ]) ]
        end
        net = report[:totals][:net_profit]
        Table.new([ headings, *rows, Table.total([ nil, nil, "Net profit (loss)", *columns.map { |column| net[column] }, net[:total] ]) ])
      end

      def cash_flow(report)
        rows = Reports::CashFlow::ACTIVITIES.flat_map do |activity|
          title = "#{activity.capitalize} activities"
          [ *report.sections.fetch(activity).map { |row| [ title, row.account&.code, row.account ? row.account.name : row.label, row.amount ] },
            Table.total([ title, nil, "Net cash from #{activity} activities", report.total(activity) ]) ]
        end
        Table.new([ [ "Section", "Code", "Account", "Amount" ], *rows,
                    Table.total([ nil, nil, "Net change in cash", report.net_change ]), Table.total([ nil, nil, "Cash at the start", report.opening ]),
                    Table.total([ nil, nil, "Cash at the end", report.closing ]) ])
      end

      # A tax return (TaxReturnCalculator's): each box's label, name and figure.
      def tax_return(report)
        Table.new([ [ "Box", "Name", "Amount" ], *report[:boxes].map { |row| [ row.box.label, row.box.name, row.amount ] } ])
      end

      # A customer's or supplier's statement (a PartyStatement): the opening balance, a row
      # per line with the running balance, and the closing balance; or (open_items) what
      # was still open at the end, then the closing balance by how overdue it is. With
      # foreign amounts (foreign: whether to have their columns), their currency and amount.
      def party_statement(statement, open_items: false, foreign: statement.foreign?)
        Table.new([ party_statement_headings(statement.type, open_items: open_items, foreign: foreign),
                    *party_statement_rows(statement, open_items: open_items, foreign: foreign) ])
      end

      # Several statements (of one type) in one table, each row headed by its party's name.
      def party_statements(statements, type:, open_items: false)
        foreign = statements.any?(&:foreign?)
        rows = statements.flat_map do |statement|
          name = PartyStatement.party_name(statement.party)
          party_statement_rows(statement, open_items: open_items, foreign: foreign).map { |row| row.is_a?(Table::TotalRow) ? Table.total([ name, *row ]) : [ name, *row ] }
        end
        Table.new([ [ PartyStatement::PARTY_NAMES.fetch(type), *party_statement_headings(type, open_items: open_items, foreign: foreign) ], *rows ])
      end

      def party_statement_headings(type, open_items:, foreign:)
        foreign_headings = foreign ? [ "Currency", open_items ? "Foreign outstanding" : "Foreign amount" ] : []
        return [ "Date", "Reference", "Details", "Due", "Days overdue", *foreign_headings, "Amount", "Outstanding" ] if open_items

        [ "Date", "Type", "Reference", "Details", "Due", *foreign_headings, PartyStatement::CHARGE_HEADINGS.fetch(type), PartyStatement::CREDIT_HEADING, "Balance" ]
      end

      def party_statement_rows(statement, open_items:, foreign:)
        foreign_cells = ->(money) { foreign ? [ money&.currency&.iso_code, money ] : [] }
        if open_items
          rows = statement.open_items.map do |line|
            entry = line[:entry]
            item = line[:carrying_amount]
            amount = item.credit? ? -item.detail.amount : item.detail.amount
            [ entry.transacted_at.to_date, entry.reference || entry.number_label, entry.particulars, (item.due_date&.to_date unless line[:credit]),
              (line[:days_outstanding] if line[:days_outstanding].positive?), *foreign_cells.call(item.forex && Money.new(item.forex.other_currency_amount_cents, item.forex.other_currency)),
              amount, line[:outstanding] ]
          end
          buckets = AgingReportGenerator::BUCKETS.map { |bucket| Table.total([ nil, nil, ReportsHelper::AGING_BUCKETS.fetch(bucket), nil, nil, *foreign_cells.call(nil), nil, statement.aging[bucket] ]) }
          return [ *rows, *buckets, Table.total([ nil, nil, "Closing balance", nil, nil, *foreign_cells.call(nil), nil, statement.closing ]) ]
        end

        rows = statement.lines.map do |line|
          entry = line.entry
          [ line.date, line.kind, entry && (entry.reference || entry.number_label), entry&.particulars, line.due_date&.to_date, *foreign_cells.call(line.foreign),
            line.charge, line.credit, line.balance ]
        end
        [ [ statement.from, nil, nil, "Opening balance", nil, *foreign_cells.call(nil), nil, nil, statement.opening ], *rows,
          Table.total([ statement.thru, nil, nil, "Closing balance", nil, *foreign_cells.call(nil), statement.charges_total, statement.credits_total, statement.closing ]) ]
      end

      # The change as a percentage of the second amount, to one decimal place; nil when it is zero.
      def percent(amounts)
        base = amounts[1]
        (BigDecimal(amounts[0].cents - base.cents) / base.cents.abs * 100).round(1) unless base.zero?
      end
    end
  end
end
