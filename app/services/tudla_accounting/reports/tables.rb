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
          [ code.code, code.name, code.kind.capitalize, BigDecimal(code.rate_percent), row[:base], row[:tax] ]
        end
        Table.new([ [ "Code", "Name", "Kind", "Rate %", "Taxed amount", "Tax" ], *rows,
                    Table.total([ nil, "Total sales", nil, nil, report[:sales][:base], report[:sales][:tax] ]),
                    Table.total([ nil, "Total purchases", nil, nil, report[:purchases][:base], report[:purchases][:tax] ]),
                    Table.total([ nil, report[:net_tax].negative? ? "Net tax refundable" : "Net tax payable", nil, nil, nil, report[:net_tax] ]) ])
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

      # A customer's or supplier's statement (a PartyStatement): the opening balance, a row
      # per line with the running balance, and the closing balance; or (open_items) what
      # was still open at the end, then the closing balance by how overdue it is. With
      # foreign amounts, their currency and amount.
      def party_statement(statement, open_items: false)
        foreign = statement.foreign?
        foreign_cells = ->(money) { foreign ? [ money&.currency&.iso_code, money ] : [] }
        foreign_headings = foreign ? [ "Currency", open_items ? "Foreign outstanding" : "Foreign amount" ] : []
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
          return Table.new([ [ "Date", "Reference", "Details", "Due", "Days overdue", *foreign_headings, "Amount", "Outstanding" ], *rows, *buckets,
                             Table.total([ nil, nil, "Closing balance", nil, nil, *foreign_cells.call(nil), nil, statement.closing ]) ])
        end

        rows = statement.lines.map do |line|
          entry = line.entry
          [ line.date, line.kind, entry && (entry.reference || entry.number_label), entry&.particulars, line.due_date&.to_date, *foreign_cells.call(line.foreign),
            line.charge, line.credit, line.balance ]
        end
        Table.new([ [ "Date", "Type", "Reference", "Details", "Due", *foreign_headings, PartyStatement::CHARGE_HEADINGS.fetch(statement.type), PartyStatement::CREDIT_HEADING, "Balance" ],
                    [ statement.from, nil, nil, "Opening balance", nil, *foreign_cells.call(nil), nil, nil, statement.opening ], *rows,
                    Table.total([ statement.thru, nil, nil, "Closing balance", nil, *foreign_cells.call(nil), statement.charges_total, statement.credits_total, statement.closing ]) ])
      end

      # The change as a percentage of the second amount, to one decimal place; nil when it is zero.
      def percent(amounts)
        base = amounts[1]
        (BigDecimal(amounts[0].cents - base.cents) / base.cents.abs * 100).round(1) unless base.zero?
      end
    end
  end
end
