# frozen_string_literal: true

module TudlaAccounting
  # Ages an organization's open receivables or payables as of a date:
  #
  #   AgingReportGenerator.call(organization: org, report_type: :receivable, as_of_date: Date.new(2026, 6, 30))
  #   # => { summary:, details:, totals:, as_of_date:, report_type: }
  #
  # Each open amount falls in a bucket by days past its due date: :current (not yet due,
  # or no due date), :days_1_30, :days_31_60, :days_61_90 or :days_over_90. summary and
  # details are keyed by related party ("ClassName_id", see the related_party_method
  # setting); totals has each bucket and :total, in the organization's currency.
  #
  # Only invoices or bills transacted by the end of as_of_date are included, and payments
  # posted after it are added back, so a past date shows what was owed on that day.
  class AgingReportGenerator
    BUCKETS = %i[current days_1_30 days_31_60 days_61_90 days_over_90].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(organization:, report_type:, as_of_date: Date.current)
      @organization = organization
      @report_type = report_type.to_sym
      @as_of_date = as_of_date
      raise ArgumentError, "Invalid report_type: #{@report_type}. Must be :receivable or :payable" unless %i[receivable payable].include?(@report_type)
    end

    def call
      lines = open_lines
      by_party = lines.group_by { |line| line[:carrying_amount].related_party }

      {
        summary: by_party.to_h { |party, party_lines| [ party_key(party), { related_party: party, aging_buckets: buckets(party_lines), total: total(party_lines) } ] },
        details: by_party.to_h { |party, party_lines| [ party_key(party), party_lines ] },
        totals: buckets(lines),
        as_of_date: @as_of_date,
        report_type: @report_type
      }
    end

    private

    def open_lines
      carrying_amounts.filter_map do |carrying_amount|
        outstanding = Money.new(carrying_amount.amount_cents + paid_after_cents(carrying_amount), @organization.currency)
        next unless outstanding.positive?

        days = days_outstanding(carrying_amount)
        { carrying_amount: carrying_amount, entry: carrying_amount.detail.entry, source: carrying_amount.detail.entry.source,
          outstanding: outstanding, days_outstanding: days, aging_bucket: bucket_for(days) }
      end
    end

    def carrying_amounts
      TudlaAccounting::CarryingAmount
        .joins(detail: :entry)
        .where(carrying_amount_type: @report_type,
               tudla_accounting_details: { organization_type: @organization.class.name, organization_id: @organization.id })
        .where(tudla_accounting_entries: { transacted_at: ..as_of_end })
        .includes(:related_party, detail: { entry: :source })
        .order("tudla_accounting_entries.transacted_at")
    end

    # Payments (or disbursements) against this amount posted after the as-of date had
    # already reduced it; add them back.
    def paid_after_cents(carrying_amount)
      checker = @report_type == :receivable ? IsAccountReceivableChecker : IsAccountPayableChecker
      TudlaAccounting::Entry
        .where(related: carrying_amount.detail.entry).where.not(posted_at: nil).where(transacted_at: (as_of_end + 1.second)..)
        .includes(details: :account)
        .sum { |payment| payment.details.find { |detail| checker.call(detail: detail) }&.amount_cents.to_i }
    end

    def as_of_end
      @as_of_date.in_time_zone(TudlaAccounting.configuration.time_zone).end_of_day
    end

    def days_outstanding(carrying_amount)
      return 0 unless carrying_amount.due_date

      (@as_of_date - carrying_amount.due_date.in_time_zone(TudlaAccounting.configuration.time_zone).to_date).to_i
    end

    def bucket_for(days)
      case days
      when ..0 then :current
      when 1..30 then :days_1_30
      when 31..60 then :days_31_60
      when 61..90 then :days_61_90
      else :days_over_90
      end
    end

    def buckets(lines)
      totals = BUCKETS.index_with { |bucket| total(lines.select { |line| line[:aging_bucket] == bucket }) }
      totals.merge(total: total(lines))
    end

    def total(lines)
      lines.sum(Money.new(0, @organization.currency)) { |line| line[:outstanding] }
    end

    def party_key(party)
      "#{party.class.name}_#{party.id}"
    end
  end
end
