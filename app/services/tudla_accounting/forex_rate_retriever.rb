# frozen_string_literal: true

module TudlaAccounting
  # Returns how many units of `to` one unit of `from` was worth on a date:
  #
  #   ForexRateRetriever.call(from: "EUR", to: "AUD", date: Date.new(2026, 3, 31)) # => 1.6431 (AUD per EUR)
  #
  # Rates are cached in the ForexRate table (an inverse rate is used if that is what is
  # stored). Missing rates come from the configured forex_rate_provider, a callable
  # taking from:, to: and date: and returning the rate (or nil if it has none), e.g.
  # RbaForexRateProvider.new for books kept in AUD.
  class ForexRateRetriever
    class RateNotFound < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(from:, to:, date:)
      @from = from.to_s.upcase
      @to = to.to_s.upcase
      @date = date.to_date
    end

    def call
      return BigDecimal("1") if @from == @to

      cached(@from, @to) || inverse(cached(@to, @from)) || fetch
    end

    private

    def cached(from, to)
      TudlaAccounting::ForexRate.find_by(from: from, to: to, year: @date.year, month: @date.month, day: @date.day)&.rate
    end

    def inverse(rate)
      BigDecimal("1") / rate if rate
    end

    def fetch
      provider = TudlaAccounting.configuration.forex_rate_provider
      raise RateNotFound, "No #{@from}/#{@to} rate for #{@date} and no forex_rate_provider configured" unless provider

      rate = provider.call(from: @from, to: @to, date: @date)
      raise RateNotFound, "No #{@from}/#{@to} rate for #{@date}" unless rate&.positive?

      rate = BigDecimal(rate.to_s)
      TudlaAccounting::ForexRate.create!(from: @from, to: @to, year: @date.year, month: @date.month, day: @date.day, rate: rate)
      rate
    end
  end
end
