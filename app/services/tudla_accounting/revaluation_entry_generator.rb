# frozen_string_literal: true

module TudlaAccounting
  # Revalues an organization's open foreign-currency receivables and payables at the
  # end of a reporting period, and reverses it at the start of the next:
  #
  #   RevaluationEntryGenerator.call(organization, Date.new(2026, 3, 31), Date.new(2026, 4, 1))
  #
  # For each open amount (booked by the period end, foreign balance not yet settled), its
  # foreign balance is valued at the period-end rate (see ForexRateRetriever) and compared
  # with its book value. The difference is posted on the period-end date between the
  # receivable/payable account and the account named by the unrealized_fx_gain_account_code
  # setting, then reversed on the next period's start date, so settlement later is not
  # double-counted. Both entries are posted and linked to the original entry through
  # `related`. Running it again for the same date does nothing more. Returns the entries.
  class RevaluationEntryGenerator
    def self.call(...)
      new(...).call
    end

    def initialize(organization, period_end_date, next_period_start_date)
      @organization = organization
      @period_end = period_end_date.to_date
      @next_start = next_period_start_date.to_date
      @gain_account_code = TudlaAccounting.configuration.unrealized_fx_gain_account_code
      raise ArgumentError, "TudlaAccounting.configuration.unrealized_fx_gain_account_code is not set" if @gain_account_code.blank?
    end

    def call
      ActiveRecord::Base.transaction do
        open_foreign_amounts.flat_map { |carrying_amount| revalue(carrying_amount) }
      end
    end

    private

    def zone
      ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone]
    end

    def open_foreign_amounts
      TudlaAccounting::CarryingAmount
        .joins(:forex, detail: :entry)
        .where(tudla_accounting_details: { organization_type: @organization.class.name, organization_id: @organization.id })
        .where.not(tudla_accounting_carrying_amount_forexes: { other_currency_amount_cents: 0 })
        .where(tudla_accounting_entries: { transacted_at: ..zone.local(@period_end.year, @period_end.month, @period_end.day).end_of_day })
        .includes(:forex, detail: [ :account, :entry ])
        .order(:id)
    end

    def revalue(carrying_amount)
      forex = carrying_amount.forex
      rate = ForexRateRetriever.call(from: forex.other_currency, to: @organization.currency, date: @period_end)
      value = Money.from_amount(Money.new(forex.other_currency_amount_cents, forex.other_currency).to_d * rate, @organization.currency)
      change = value - Money.new(carrying_amount.amount_cents, @organization.currency) # change in the account's balance
      return [] if change.zero?

      original = carrying_amount.detail.entry
      account = carrying_amount.detail.account
      particulars = "Revaluation of #{account.name}"
      return [] if TudlaAccounting::Entry.exists?(organization: @organization, related: original, particulars: particulars,
                                                  transacted_at: start_of(@period_end))

      gain = carrying_amount.payable? ? -change : change # a liability growing is a loss
      [
        post_entry(particulars, @period_end, original, account, change, gain),
        post_entry("Reversal of #{particulars}", @next_start, original, account, -change, -gain)
      ]
    end

    # No source, so posting it does not open or settle carrying amounts.
    def post_entry(particulars, date, original, account, account_change, gain)
      entry = TudlaAccounting::Entry.create_from_ruby_hash(
        organization_type: @organization.class.name, organization_id: @organization.id,
        particulars: particulars, transacted_at: start_of(date).iso8601,
        details: [ { account_code: account.code, amount: amount(account_change) },
                   { account_code: @gain_account_code, amount: amount(gain) } ]
      )
      entry.update!(related: original)
      entry.post(entry.transacted_at)
      entry
    end

    def start_of(date)
      zone.local(date.year, date.month, date.day)
    end

    def amount(money)
      "#{money.currency.iso_code} #{money}"
    end
  end
end
