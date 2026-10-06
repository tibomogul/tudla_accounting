# frozen_string_literal: true

module TudlaAccounting
  # Reconciles a bank account's imported statement lines with its posted ledger lines:
  #
  #   reconciler = BankReconciler.new(account)
  #   reconciler.suggestions                      # => { statement_line => ledger_line }
  #   reconciler.match!(statement_line, [ledger_line])
  #   reconciler.create_entry!(statement_line, account: bank_fees)   # posts it, then matches
  #   reconciler.summary(as_of: Date.new(2026, 3, 31))
  #
  # Amounts are as the bank sees them, in the account's currency: money in (a debit to
  # the account) positive, money out (a credit) negative. A foreign-currency account's
  # ledger lines are compared by their foreign amount.
  class BankReconciler
    SUGGESTION_DAYS = 7

    attr_reader :account

    def initialize(account)
      @account = account
      @organization = account.organization
    end

    def foreign?
      account.currency.present? && account.currency != @organization.currency
    end

    def currency
      foreign? ? account.currency : @organization.currency
    end

    # The ledger line's amount as the bank sees it, or nil when it can't be compared (a
    # foreign-currency account's line without a foreign amount).
    def bank_cents(detail)
      cents = foreign? ? detail.foreign_exchange&.other_currency_cents : detail.amount_cents
      cents && (detail.debit? ? cents : -cents)
    end

    def statement_lines
      BankStatementLine.where(account: account)
    end

    # Posted lines on the account not matched to a statement line (posted by the end of
    # thru, a date, when given).
    def unmatched_ledger(thru: nil)
      details = Detail.joins(:entry).where(account: account).where.not(tudla_accounting_entries: { posted_at: nil }).where.missing(:bank_match)
      details = details.where(tudla_accounting_entries: { posted_at: ..end_of(thru) }) if thru
      details.includes(:entry, :foreign_exchange).order("tudla_accounting_entries.posted_at", :id)
    end

    # For each unmatched statement line, an unmatched ledger line for the same amount
    # posted within SUGGESTION_DAYS of it (the closest), each used once.
    def suggestions
      candidates = unmatched_ledger.to_a
      statement_lines.unmatched.order(:occurred_on, :id).each_with_object({}) do |line, found|
        best = candidates.select { |detail| bank_cents(detail) == line.amount_cents && days_apart(line, detail) <= SUGGESTION_DAYS }
          .min_by { |detail| [ days_apart(line, detail), detail.id ] }
        next unless best

        found[line] = best
        candidates.delete(best)
      end
    end

    def match_suggestions!
      suggestions.each { |line, detail| match!(line, [ detail ]) }.size
    end

    # Matches a statement line to the ledger lines (on this account, posted, not matched
    # yet) whose amounts add up to it.
    def match!(line, details)
      details = Array(details)
      raise ArgumentError, "That statement line is for another account" unless line.account_id == account.id
      raise ArgumentError, "That statement line is matched already" if line.matched?
      raise ArgumentError, "Choose the ledger lines it matches" if details.empty?
      raise ArgumentError, "Only posted lines on #{account.code_with_name} can be matched" unless details.all? { |d| d.account_id == account.id && d.entry.posted? }
      raise ArgumentError, "A ledger line is matched to another statement line already" if BankMatch.exists?(detail: details)

      total = details.sum { |detail| bank_cents(detail) || raise(ArgumentError, "A ledger line has no #{currency} amount to compare") }
      raise ArgumentError, "The ledger lines add up to #{plain(total)} but the statement line is #{plain(line.amount_cents)}" unless total == line.amount_cents

      ActiveRecord::Base.transaction do
        details.each { |detail| BankMatch.create!(organization: @organization, bank_statement_line: line, detail: detail) }
        AuditEvent.record!("bank_line.matched", organization: @organization, subject: line, details: { detail_ids: details.map(&:id) })
      end
      line.reload
    end

    def unmatch!(line)
      raise ArgumentError, "That statement line isn't matched" unless line.matched?

      ActiveRecord::Base.transaction do
        line.bank_matches.destroy_all
        AuditEvent.record!("bank_line.unmatched", organization: @organization, subject: line)
      end
      line.reload
    end

    # Posts an entry for a statement line the books don't have yet (a bank fee, interest),
    # between the bank account and another account, dated with the line, and matches it.
    def create_entry!(line, account:, particulars: nil)
      raise ArgumentError, "Entries can only be created for an account in #{@organization.currency}" if foreign?
      raise ArgumentError, "Choose another account than the bank account" if account == self.account
      raise ArgumentError, "That statement line is matched already" if line.matched?

      ActiveRecord::Base.transaction do
        at = ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].local(line.occurred_on.year, line.occurred_on.month, line.occurred_on.day)
        money_in = line.amount_cents.positive?
        entry = Entry.new(organization: @organization, transacted_at: at, particulars: particulars.presence || line.description)
        entry.details.build(account: self.account, tally: money_in ? Detail::TALLY_DEBIT : Detail::TALLY_CREDIT, amount_cents: line.amount_cents.abs, currency: currency)
        entry.details.build(account: account, tally: money_in ? Detail::TALLY_CREDIT : Detail::TALLY_DEBIT, amount_cents: line.amount_cents.abs, currency: currency)
        entry.save!
        entry.post(at)
        match!(line, [ entry.details.find { |detail| detail.account_id == self.account.id } ])
        entry
      end
    end

    # Whether the books agree with the bank as at a date. The book balance (opening
    # balance and every posted line to then), less what the bank hasn't shown yet (ledger
    # lines not matched) plus what the books don't have yet (statement lines not
    # matched), is what the statement should say; difference is from the balance on the
    # last statement line to that date that gives one (nil without one). A
    # foreign-currency account has no book balance in its own currency, so only the
    # unmatched totals are given.
    def summary(as_of:)
      unmatched_ledger_cents = unmatched_ledger(thru: as_of).sum { |detail| bank_cents(detail).to_i }
      unmatched_statement_cents = statement_lines.unmatched.where(occurred_on: ..as_of).sum(:amount_cents)
      last_balance = statement_lines.where(occurred_on: ..as_of).where.not(balance_cents: nil).order(:occurred_on, :id).last
      book_cents = foreign? ? nil : book_balance_cents(as_of)
      expected = book_cents && book_cents - unmatched_ledger_cents + unmatched_statement_cents

      { as_of: as_of, book_balance: book_cents && money(book_cents), unmatched_ledger: money(unmatched_ledger_cents),
        unmatched_statement: money(unmatched_statement_cents), expected_statement_balance: expected && money(expected),
        statement_balance: last_balance&.balance, statement_balance_on: last_balance&.occurred_on,
        difference: (last_balance && expected) ? money(last_balance.balance_cents - expected) : nil }
    end

    private

    def book_balance_cents(as_of)
      first_year = Period.roots.where(organization: @organization).order(:from_date).first
      opening = first_year ? Balance.find_by(account: account, period: first_year)&.starting_amount_cents.to_i : 0
      opening = -opening unless account.debit_balance? # money in is a debit, whichever side the account keeps
      posted = Detail.joins(:entry).where(account: account).where(tudla_accounting_entries: { posted_at: ..end_of(as_of) })
        .group(:tally).sum(:amount_cents)
      opening + posted.fetch(Detail::TALLY_DEBIT, 0) - posted.fetch(Detail::TALLY_CREDIT, 0)
    end

    def days_apart(line, detail)
      (line.occurred_on - detail.entry.posted_at.in_time_zone(TudlaAccounting.configuration.time_zone).to_date).abs
    end

    def end_of(date)
      ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].local(date.year, date.month, date.day).end_of_day
    end

    def plain(cents)
      "#{currency} #{money(cents).format(symbol: false)}"
    end

    def money(cents)
      Money.new(cents, currency)
    end
  end
end
