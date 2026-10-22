# frozen_string_literal: true

module TudlaAccounting
  # A record whose amounts can be in another currency than its organization's (Document,
  # Payment): currency, nil for the organization's own, and exchange_rate, how many of the
  # organization's currency one unit of it was worth, which converts its amounts for
  # posting. A foreign one given no rate gets the date's from ForexRateRetriever, when it
  # has one.
  module ForeignCurrency
    extend ActiveSupport::Concern

    included do
      normalizes :currency, with: ->(currency) { currency.strip.upcase.presence }
    end

    # Its currency: the organization's unless it is foreign.
    def currency = self[:currency] || organization&.currency || TudlaAccounting.configuration.base_currency
    def foreign? = self[:currency].present?

    # An amount of its currency in the organization's, at its rate.
    def in_base_cents(cents)
      foreign? ? (cents * exchange_rate).round(0, TudlaAccounting.configuration.rounding).to_i : cents
    end

    private

    # The organization's own currency is kept as none, and a foreign one without a rate
    # gets the rate for the date on, if there is one.
    def settle_currency(on)
      self.currency = nil if self[:currency] == organization&.currency
      return self.exchange_rate = nil unless foreign?
      return if exchange_rate || on.nil? || !Money::Currency.find(self[:currency])

      self.exchange_rate = ForexRateRetriever.call(from: currency, to: organization.currency, date: on)
    rescue ForexRateRetriever::RateNotFound
      nil
    end

    # A known currency, and a rate for it (on: the date it is for).
    def currency_rated(on)
      return unless foreign?
      return errors.add(:currency, "is not a known currency code") unless Money::Currency.find(self[:currency])

      if exchange_rate.nil?
        errors.add(:exchange_rate, "is needed: no #{currency} rate was found for #{on&.strftime('%-d %b %Y')}")
      elsif !exchange_rate.positive?
        errors.add(:exchange_rate, "must be more than zero")
      end
    end
  end
end
