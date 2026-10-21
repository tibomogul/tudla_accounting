# frozen_string_literal: true

module TudlaAccounting
  # A statement of account for one customer (type :receivable) or supplier (:payable)
  # over a run of days, as it would be sent to them:
  #
  #   statement = PartyStatement.call(organization: org, type: :receivable, party: customer,
  #                                   from: Date.new(2026, 3, 1), thru: Date.new(2026, 3, 31))
  #   statement.opening   # what they owed at the end of the day before `from`
  #   statement.lines     # what happened in between, with a running balance
  #   statement.closing   # what they owed at the end of `thru`
  #   statement.aging     # the closing balance by how overdue it is (AgingReportGenerator's buckets)
  #   statement.open_items # what was still open at the end of `thru` (AgingReportGenerator's lines)
  #
  # Balances are what the aging report shows for the party: charges (invoices, bills,
  # refunds) less credits (payments, disbursements, credit notes), each as far as it was
  # still open, so a positive balance is owed by a customer or to a supplier. The lines
  # are the charges and credits dated in the run at their full amounts, and the reversals
  # of any (on the reversal's date). Settling a foreign-currency amount at another rate
  # than it was booked at moves the balance by the difference, which no line shows; an
  # adjustment line before the closing balance takes it up, so the running balance ends
  # there. Amounts are in the organization's currency (a foreign amount is on its line).
  #
  # Parties are the records the related_party_method setting gives (the organization
  # itself when there is none): PartyStatement.parties lists those with receivables or
  # payables, and key names one in a URL.
  class PartyStatement
    Line = Struct.new(:date, :entry, :kind, :due_date, :charge, :credit, :balance, :foreign, keyword_init: true)

    KINDS = { receivable: "Invoice", payable: "Bill", receipt: "Payment", disbursement: "Payment", credit_note: "Credit note",
              supplier_credit: "Credit note", refund: "Refund", supplier_refund: "Refund" }.freeze
    ADJUSTMENT = "Exchange differences on settlement and other adjustments"
    PARTY_NAMES = { receivable: "Customer", payable: "Supplier" }.freeze
    CHARGE_HEADINGS = { receivable: "Invoiced", payable: "Billed" }.freeze
    CREDIT_HEADING = "Paid or credited"

    attr_reader :organization, :type, :party, :from, :thru, :opening, :lines, :closing, :aging, :open_items

    def self.call(...) = new(...).call

    # The parties with receivables (or payables), by name.
    def self.parties(organization, type)
      carrying_amounts(organization, type).distinct.pluck(:related_party_type, :related_party_id)
        .group_by(&:first).flat_map { |class_name, ids| class_name.constantize.where(id: ids.map(&:last)).to_a }
        .sort_by { |party| party_name(party).downcase }
    end

    # "Customer_12", for a URL.
    def self.key(party)
      "#{party.class.name}_#{party.id}"
    end

    # Its name, or "Organization #4".
    def self.party_name(party)
      party.respond_to?(:name) && party.name.present? ? party.name : "#{party.class.name.demodulize} ##{party.id}"
    end

    def self.carrying_amounts(organization, type)
      CarryingAmount.joins(detail: :entry).where(carrying_amount_type: type, tudla_accounting_details: { organization_type: organization.class.name, organization_id: organization.id })
    end

    def initialize(organization:, type:, party:, from:, thru:)
      raise ArgumentError, "Invalid type: #{type}. Must be :receivable or :payable" unless %i[receivable payable].include?(type.to_sym)
      raise ArgumentError, "The statement must start on or before its end" if from > thru

      @organization = organization
      @type = type.to_sym
      @party = party
      @from = from
      @thru = thru
    end

    def call
      items = self.class.carrying_amounts(organization, type).where(related_party: party).where(tudla_accounting_entries: { transacted_at: ..end_of(thru) })
                  .includes(:forex, detail: { entry: :source }).order("tudla_accounting_entries.transacted_at", :id).to_a
      reversals = Entry.where(related: items.map { |item| item.detail.entry }).where.not(posted_at: nil).where("particulars LIKE ?", "#{Entry::REVERSAL_PREFIX}%")
                       .index_by(&:related_id)
      before = end_of(from - 1)
      @opening = money(items.sum { |item| item.detail.entry.transacted_at <= before ? item.outstanding(as_of: before)[:cents] : 0 })
      report = AgingReportGenerator.call(organization: organization, report_type: type, as_of_date: thru, party: party)
      @open_items = report[:details].values.first || []
      @aging = report[:totals]
      @closing = @aging[:total]
      @lines = activity(items, reversals)
      self
    end

    # Whether there is nothing to send: no balance at either end and nothing in between.
    def empty?
      opening.zero? && closing.zero? && lines.empty?
    end

    def charges_total = lines.sum(money(0)) { |line| line.charge || money(0) }
    def credits_total = lines.sum(money(0)) { |line| line.credit || money(0) }

    # Whether a line has a foreign amount (for a column of them).
    def foreign?
      lines.any?(&:foreign) || open_items.any? { |line| line[:carrying_amount].forex }
    end

    private

    # The run's charges, credits and reversals in date order, with the running balance,
    # and the adjustment that brings it to the closing balance.
    def activity(items, reversals)
      run = from.in_time_zone(TudlaAccounting.configuration.time_zone).beginning_of_day..end_of(thru)
      events = items.filter_map { |item| [ item.detail.entry.transacted_at, item, false ] if run.cover?(item.detail.entry.transacted_at) }
      events += items.filter_map do |item|
        reversal = reversals[item.detail.entry.id]
        [ reversal.transacted_at, item, reversal ] if reversal && run.cover?(reversal.transacted_at)
      end
      balance = opening
      lines = events.sort_by { |at, item, reversal| [ at, reversal ? 1 : 0, item.id ] }.map do |at, item, reversal|
        amount = money(item.detail.amount_cents)
        amount = -amount if item.credit?
        amount = -amount if reversal
        balance += amount
        Line.new(date: at.to_date, entry: reversal || item.detail.entry, kind: reversal ? "Reversal" : kind(item), due_date: (item.due_date if item.charge? && !reversal),
                 charge: (amount if amount.positive?), credit: (-amount if amount.negative?), balance: balance, foreign: (foreign(item, reversal) if item.forex))
      end
      difference = closing - balance
      lines << Line.new(date: thru, kind: ADJUSTMENT, charge: (difference if difference.positive?), credit: (-difference if difference.negative?), balance: closing) unless difference.zero?
      lines
    end

    # What the item is, by its source's role; an imported open item (with no source) is an
    # invoice or bill.
    def kind(item)
      KINDS[CarryingAmountRole.call(entry: item.detail.entry)] || KINDS.fetch(type)
    end

    # The line's amount in its own currency, on the same side as the line.
    def foreign(item, reversal)
      cents = item.opening_foreign_cents.abs
      cents = -cents if item.credit? ^ reversal.present?
      Money.new(cents, item.forex.other_currency)
    end

    def end_of(date)
      date.in_time_zone(TudlaAccounting.configuration.time_zone).end_of_day
    end

    def money(cents)
      Money.new(cents, organization.currency)
    end
  end
end
