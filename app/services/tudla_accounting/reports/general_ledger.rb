# frozen_string_literal: true

require "csv"

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
          opening = Balance.peek(account, from).starting_amount
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

      def total_debits
        accounts.sum(zero) { |section| section.lines.filter_map(&:debit).sum(zero) }
      end

      def total_credits
        accounts.sum(zero) { |section| section.lines.filter_map(&:credit).sum(zero) }
      end

      # Date, Account code, Account, Entry, Debit, Credit, Balance; an opening and a closing
      # row per account.
      def to_csv
        CSV.generate do |csv|
          csv << [ "Date", "Account code", "Account", "Entry", "Debit", "Credit", "Balance" ]
          accounts.each do |section|
            account = section.account
            csv << [ from.from_date.to_date.iso8601, account.code, account.name, "Opening balance", nil, nil, plain(section.opening) ]
            section.lines.each do |line|
              csv << [ line.date.to_date.iso8601, account.code, account.name, line.entry.particulars, plain(line.debit), plain(line.credit), plain(line.balance) ]
            end
            csv << [ thru.thru_date.to_date.iso8601, account.code, account.name, "Closing balance", nil, nil, plain(section.closing) ]
          end
        end
      end

      private

      def candidates
        @candidates ||= begin
          all = Account.where(organization: @organization).order(:code).to_a
          parent_ids = all.filter_map(&:parent_id).to_set
          all.reject { |account| parent_ids.include?(account.id) || (@account_ids && !@account_ids.include?(account.id)) }
        end
      end

      def details_by_account
        @details_by_account ||= Detail.joins(:entry).where(account_id: candidates.map(&:id))
          .where(tudla_accounting_entries: { posted_at: from.from_date..thru.thru_date })
          .includes(:entry).order("tudla_accounting_entries.posted_at", "tudla_accounting_entries.id", :id)
          .group_by(&:account_id)
      end

      def plain(money)
        money&.format(symbol: false, thousands_separator: "")
      end

      def zero
        Money.new(0, @organization.currency)
      end
    end
  end
end
