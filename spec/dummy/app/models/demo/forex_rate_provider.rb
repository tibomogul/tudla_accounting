# Made-up rates between the dollar, the euro and the peso for the demo, for any date, so a
# foreign invoice or payment left without a rate gets the day's (ForexRateRetriever keeps
# each one the first time it's asked for). They drift a little around 1 USD = 0.92 EUR =
# 62.50 PHP, each on its own wave, and are given to six significant figures; not real rates.
#
#   Demo::ForexRateProvider.new.call(from: "USD", to: "EUR", date: Date.new(2026, 11, 2)) # => 0.9052
class Demo::ForexRateProvider
  EUR_PER_USD = BigDecimal("0.92")
  PHP_PER_USD = BigDecimal("62.5")

  def call(from:, to:, date:)
    from_per_usd, to_per_usd = [ from, to ].map { |currency| per_usd(currency, date) }
    rate = to_per_usd / from_per_usd if from_per_usd && to_per_usd && from != to
    rate&.round(6 - rate.exponent)
  end

  private

  def per_usd(currency, date)
    case currency
    when "USD" then BigDecimal("1")
    when "EUR" then drift(EUR_PER_USD, date, 30.0)
    when "PHP" then drift(PHP_PER_USD, date, 45.0)
    end
  end

  # A slow wave of a couple of percent either way, a cycle every six to nine months.
  def drift(rate, date, days)
    (rate * (1 + BigDecimal(Math.sin(date.jd / days).to_s) / 50)).round(4)
  end
end
