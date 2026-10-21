# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # Every posted line, account by account, over a run of months: each account's opening
    # balance, its lines with a running balance, and its closing balance, all on the
    # account's own side (as its balances are kept). Covers the accounts lines are posted
    # to (those without sub-accounts) that have a balance or postings; account_ids narrows it.
    #
    #   GeneralLedger.new(organization, from: march, thru: june).accounts
    #   # => [#<Section account=1000 opening=... lines=[#<Line ...>] closing=...>, ...]
    class GeneralLedger
      Section = Struct.new(:account, :opening, :lines, :closing, keyword_init: true)
      Line = Struct.new(:detail, :entry, :date, :debit, :credit, :balance, keyword_init: true)

      attr_reader :from, :thru

      # from and thru are months (leaf periods); thru is included.
      def initialize(organization, from:, thru:, account_ids: nil)
        @organization = organization
        @from = from
        @thru = thru
        @account_ids = account_ids
      end

      def accounts
        @accounts ||= candidates.filter_map do |account|
          opening = openings.fetch(account.id).starting_amount
          details = details_by_account.fetch(account.id, [])
          next if details.empty? && opening.zero?

          balance = opening
          lines = details.map do |detail|
            balance += detail.debit? == account.debit_balance? ? detail.amount : -detail.amount
            Line.new(detail: detail, entry: detail.entry, date: detail.entry.posted_at, debit: (detail.amount if detail.debit?),
                     credit: (detail.amount if detail.credit?), balance: balance)
          end
          Section.new(account: account, opening: opening, lines: lines, closing: balance)
        end
      end

      # [section, line] for every line, account by account ([section, nil] for an account
      # with a balance but no lines), for showing a page at a time.
      def rows
        accounts.flat_map { |section| section.lines.empty? ? [ [ section, nil ] ] : section.lines.map { |line| [ section, line ] } }
      end

      def total_debits
        accounts.sum(zero) { |section| section.lines.filter_map(&:debit).sum(zero) }
      end

      def total_credits
        accounts.sum(zero) { |section| section.lines.filter_map(&:credit).sum(zero) }
      end

      # Date, Entry no., Reference, Account code, Account, Entry, Description (the line's),
      # Debit, Credit, Balance; an opening and a closing row per account.
      def to_table
        rows = accounts.flat_map do |section|
          account = section.account
          [ [ from.from_date, nil, nil, account.code, account.name, "Opening balance", nil, nil, nil, section.opening ],
            *section.lines.map do |line|
              [ line.date, line.entry.number_label, line.entry.reference, account.code, account.name, line.entry.particulars,
                line.detail.description, line.debit, line.credit, line.balance ]
            end,
            [ thru.thru_date, nil, nil, account.code, account.name, "Closing balance", nil, nil, nil, section.closing ] ]
        end
        Table.new([ [ "Date", "Entry no.", "Reference", "Account code", "Account", "Entry", "Description", "Debit", "Credit", "Balance" ], *rows ])
      end

      def to_csv
        to_table.to_csv
      end

      private

      def candidates
        @candidates ||= begin
          all = Account.where(organization: @organization).order(:code).to_a
          parent_ids = all.filter_map(&:parent_id).to_set
          all.reject { |account| parent_ids.include?(account.id) || (@account_ids && !@account_ids.include?(account.id)) }
        end
      end

      def openings
        @openings ||= Balance.peek_all(candidates, from)
      end

      def details_by_account
        @details_by_account ||= Detail.joins(:entry).where(account_id: candidates.map(&:id))
          .where(tudla_accounting_entries: { posted_at: from.from_date..thru.thru_date })
          .includes(:entry).order("tudla_accounting_entries.posted_at", "tudla_accounting_entries.id", :id)
          .group_by(&:account_id)
      end

      def zero
        Money.new(0, @organization.currency)
      end
    end
  end
end
