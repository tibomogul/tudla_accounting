# frozen_string_literal: true

module TudlaAccounting
  # The exchange gain (positive) or loss (negative) on a foreign-currency amount of a
  # receivable or payable, between the rate it was booked at and the rate on a date, in
  # the organization's currency:
  #
  #   ForexGainOrLossCalculator.call(amount: Money.from_amount(1000, "EUR"), conversion_date: Date.new(2026, 3, 31),
  #                                  carrying_amount: receivable)
  #
  # A receivable gains when the foreign currency strengthens; a payable loses.
  class ForexGainOrLossCalculator
    def self.call(...)
      new(...).call
    end

    def initialize(amount:, conversion_date:, carrying_amount:)
      @amount = amount.is_a?(Money) ? amount.to_d : amount
      raise ArgumentError, "Amount must be a BigDecimal or Money" unless @amount.is_a?(BigDecimal)
      raise ArgumentError, "conversion_date must be a Date" unless conversion_date.is_a?(Date)
      raise ArgumentError, "carrying_amount must be a TudlaAccounting::CarryingAmount" unless carrying_amount.is_a?(TudlaAccounting::CarryingAmount)
      raise ArgumentError, "CarryingAmount must have a foreign exchange record" unless carrying_amount.forex

      @conversion_date = conversion_date
      @carrying_amount = carrying_amount
    end

    def call
      forex = @carrying_amount.forex
      functional = @carrying_amount.detail.organization.currency
      rate = ForexRateRetriever.call(from: forex.other_currency, to: functional, date: @conversion_date)

      change = @amount * (rate - forex.transaction_rate) # in functional currency
      Money.from_amount(@carrying_amount.payable? ? -change : change, functional)
    end
  end
end
