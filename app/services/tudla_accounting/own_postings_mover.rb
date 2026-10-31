# frozen_string_literal: true

module TudlaAccounting
  # Moves an account's posted lines of its own onto one of its sub-accounts, for books
  # posted before only accounts without sub-accounts took postings (BalanceRebuilder's
  # own_amounts lists them). The account's balances stay as they are, since it holds its
  # sub-accounts' amounts; the sub-account's are rebuilt to take the lines.
  #
  #   OwnPostingsMover.call(expenses, to: bank_fees) # => the number of lines moved
  #
  # Correcting entries can't do this, as a line on an account with sub-accounts isn't
  # posted. Lines in closed periods are refused, so a closed period's figures don't move.
  class OwnPostingsMover
    attr_reader :account, :to

    def self.call(...)
      new(...).call
    end

    def initialize(account, to:)
      @account = account
      @to = to
    end

    def call
      ActiveRecord::Base.transaction do
        organization.class.lock.find(organization.id) # same lock as posting
        lines = posted_lines
        problem = blocker(lines)
        raise ArgumentError, problem if problem

        ids = lines.pluck(:id)
        entries = lines.distinct.count(:entry_id)
        DatabaseProtection.allowing_posted_changes { Detail.where(id: ids).update_all(account_id: to.id, updated_at: Time.current) }
        BalanceRebuilder.new(organization).rebuild!
        AuditEvent.record!("account.postings_moved", organization: organization, subject: account, details: { to: to.code, lines: ids.size, entries: entries })
        ids.size
      end
    end

    private

    def organization
      account.organization
    end

    def posted_lines
      Detail.joins(:entry).where(account: account).where.not(tudla_accounting_entries: { posted_at: nil })
    end

    def blocker(lines)
      currencies = lines.distinct.pluck(:currency)
      closed = Period.where(organization: organization).where.not(closed_at: nil)
                     .where("EXISTS (SELECT 1 FROM tudla_accounting_details line JOIN tudla_accounting_entries entry ON entry.id = line.entry_id " \
                            "WHERE line.account_id = ? AND entry.posted_at BETWEEN tudla_accounting_periods.from_date AND tudla_accounting_periods.thru_date)", account.id)
                     .order(:from_date).first
      if to.parent_id != account.id then "#{to.code_with_name} isn't a sub-account of #{account.code_with_name}"
      elsif (reason = to.posting_blocker) then reason
      elsif currencies.empty? then "#{account.code_with_name} has no postings of its own"
      elsif to.currency && currencies != [ to.currency ] then "#{to.code_with_name} is held in #{to.currency}, but the lines are in #{currencies.sort.join(", ")}"
      elsif closed then "#{closed.label} is closed; reopen it to move its lines"
      end
    end
  end
end
