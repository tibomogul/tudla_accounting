# frozen_string_literal: true

module TudlaAccounting
  module Reports
    # The tax withheld over a run of months, from WithheldTax rows, in the organization's
    # currency: a summary by code and month for filing (the Philippines' 0619-E and
    # 1601-EQ), the list of suppliers it was withheld from (the QAP), and the list of
    # customers who withheld it with their certificates in (the SAWT).
    #
    # Reversals and supplier credits count in the months they were dated, so an earlier
    # quarter stays as it was, and a list can show a negative for one. What nets to nothing
    # is left out. checks compares the rows with the movement on the codes' accounts. What
    # takes the account down in entries that withheld nothing (a payment to the tax
    # authority, or creditable tax claimed against tax due) is expected, and shown apart as
    # settled; a difference left is tax entered by hand, or on an advance, which the rows
    # don't include.
    #
    #   report = Withholding.new(organization, from: january, thru: march)
    #   report.summary("from_supplier") # => [#<SummaryRow code months base withheld>, ...]
    #   report.qap                      # => [#<ListRow contact code base withheld>, ...]
    class Withholding
      SummaryRow = Data.define(:code, :months, :base, :withheld)
      ListRow = Data.define(:contact, :code, :base, :withheld)
      Check = Data.define(:account, :listed, :movement, :settled) do
        def difference = movement - listed + settled
      end
      ACCOUNTS = { "from_supplier" => :payable_account, "by_customer" => :creditable_account }.freeze

      attr_reader :organization, :from, :thru

      def initialize(organization, from:, thru:)
        @organization = organization
        @from = from
        @thru = thru
      end

      # The first day of each month covered.
      def months
        first, last = from.from_date.to_date, thru.thru_date.to_date
        (0..((last.year * 12 + last.month) - (first.year * 12 + first.month))).map { |index| first.beginning_of_month >> index }
      end

      def any_codes? = codes.any?

      # A row per code with something in the months.
      def summary(direction)
        by_month = rows(direction).group(:withholding_code_id, Arel.sql("to_char(#{table}.on, 'YYYY-MM')")).pluck(:withholding_code_id, Arel.sql("to_char(#{table}.on, 'YYYY-MM')"), *SUMS)
        by_month.group_by(&:first).filter_map do |code_id, held|
          base, withheld = held.sum { |row| row[2] }, held.sum { |row| row[3] }
          next if base.zero? && withheld.zero?

          amounts = held.to_h { |_code, month, _base, tax| [ month, tax ] }
          SummaryRow.new(code: codes.fetch(code_id), months: months.map { |month| money(amounts.fetch(month.strftime("%Y-%m"), 0)) }, base: money(base), withheld: money(withheld))
        end.sort_by { |row| row.code.code }
      end

      def month_totals(direction) = months.each_index.map { |index| summary(direction).sum(money(0)) { |row| row.months[index] } }

      def qap = @qap ||= list(rows("from_supplier"))
      def sawt = @sawt ||= list(rows("by_customer").certificate_received)

      # All of it, as the summary and the accounts have it.
      def total(direction) = money(rows(direction).sum(:withheld_cents))

      # What the SAWT leaves out: amounts still waiting for a certificate, and what is left
      # of amounts reversed (nothing, when the reversal is in the same months).
      def waiting = money(rows("by_customer").certificate_waiting.sum(:withheld_cents))
      def reversed = total("by_customer") - sawt.sum(money(0), &:withheld) - waiting

      # An account a row, for the codes with that side's account.
      def checks(direction)
        attribute = ACCOUNTS.fetch(direction)
        codes.values.select(&attribute).group_by(&attribute).sort_by { |account, _| account.code }.map do |account, held|
          code_ids = held.map(&:id)
          Check.new(account: account, listed: money(rows(direction).where(withholding_code_id: code_ids).sum(:withheld_cents)), movement: movement(account),
                    settled: settled(account))
        end
      end

      private

      SUMS = [ Arel.sql("SUM(base_cents)"), Arel.sql("SUM(withheld_cents)") ].freeze
      private_constant :SUMS

      def table = WithheldTax.quoted_table_name

      def rows(direction)
        WithheldTax.where(organization: organization, direction: direction, on: from.from_date.to_date..thru.thru_date.to_date)
      end

      def codes
        @codes ||= WithholdingCode.where(organization: organization).includes(:payable_account, :creditable_account).index_by(&:id)
      end

      def list(scope)
        held = scope.group(:contact_id, :withholding_code_id).pluck(:contact_id, :withholding_code_id, *SUMS)
        contacts = Contact.where(id: held.map(&:first)).index_by(&:id)
        held.filter_map do |contact_id, code_id, base, withheld|
          next if base.zero? && withheld.zero?

          ListRow.new(contact: contacts.fetch(contact_id), code: codes.fetch(code_id), base: money(base), withheld: money(withheld))
        end.sort_by { |row| [ row.contact.name.downcase, row.code.code ] }
      end

      # What was posted to the account and those beneath it in the months, on its natural
      # side.
      def movement(account)
        sums = Detail.joins(:entry).where(account_id: account.subtree_ids, tudla_accounting_entries: { posted_at: from.from_date..thru.thru_date }).group(:tally).sum(:amount_cents)
        debits = sums.fetch(Detail::TALLY_DEBIT, 0) - sums.fetch(Detail::TALLY_CREDIT, 0)
        money(account.debit_balance? ? debits : -debits)
      end

      # What took the account down in the months in entries that withheld nothing (nor
      # reverse one that did): paid to the tax authority, or claimed against tax due.
      # Positive.
      def settled(account)
        withheld = WithheldTax.where(organization: organization).select(:entry_id)
        withholding = Entry.where(id: withheld).or(Entry.where(reversal_of_id: withheld)).select(:id)
        lines = Detail.joins(:entry).where(account_id: account.subtree_ids, tudla_accounting_entries: { posted_at: from.from_date..thru.thru_date })
                      .where.not(entry_id: withholding)
        money(lines.where(tally: account.debit_balance? ? Detail::TALLY_CREDIT : Detail::TALLY_DEBIT).sum(:amount_cents))
      end

      def money(cents) = Money.new(cents, organization.currency)
    end
  end
end
