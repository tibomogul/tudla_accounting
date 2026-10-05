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
  # Only invoices or bills transacted by the end of as_of_date are included, and only
  # payments posted against them by then count, so a past date shows what was owed on
  # that day (including foreign-currency settlements, at their booked value).
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
        outstanding = Money.new(outstanding_cents(carrying_amount), @organization.currency)
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

    # What was owed at the end of the as-of date: the amount as booked, less each payment
    # (or disbursement) posted against it by then, settled the way the processor settles it.
    def outstanding_cents(carrying_amount)
      original = carrying_amount.detail
      remaining = original.amount_cents
      remaining_foreign = original.foreign_exchange&.other_currency_cents.to_i
      forex = carrying_amount.forex

      settlements_by_as_of(original.entry).each do |line, fx|
        if forex && fx
          remaining -= TudlaAccounting::CarryingAmount.settlement(
            remaining_cents: remaining, remaining_foreign_cents: remaining_foreign, transaction_rate: forex.transaction_rate,
            foreign_currency: forex.other_currency, currency: line.currency, cash_cents: line.amount_cents, paid_foreign_cents: fx.other_currency_cents
          )[:reduction_cents]
          remaining_foreign -= fx.other_currency_cents
        else
          remaining -= line.amount_cents
        end
      end
      remaining
    end

    # [settlement line, its foreign exchange] for each receipt (or disbursement) posted
    # against the entry by the as-of date, in order. Revaluations, which are also related
    # to the entry, are not settlements.
    def settlements_by_as_of(entry)
      checker = @report_type == :receivable ? IsAccountReceivableChecker : IsAccountPayableChecker
      role = @report_type == :receivable ? :receipt : :disbursement
      TudlaAccounting::Entry
        .where(related: entry).where.not(posted_at: nil).where(transacted_at: ..as_of_end)
        .includes(details: [ :account, :foreign_exchange ]).order(:transacted_at, :id)
        .select { |payment| CarryingAmountRole.call(entry: payment) == role }
        .filter_map do |payment|
          line = payment.details.find { |detail| checker.call(detail: detail) }
          [ line, line.foreign_exchange || payment.details.filter_map(&:foreign_exchange).first ] if line
        end
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
