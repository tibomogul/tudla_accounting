# Made-up dollar and euro rates for the demo, for any date, so a foreign invoice or
# payment left without a rate gets the day's (ForexRateRetriever keeps each one the first
# time it's asked for). They drift a little around 1 USD = 0.92 EUR; not real rates.
#
#   Demo::ForexRateProvider.new.call(from: "USD", to: "EUR", date: Date.new(2026, 11, 2)) # => 0.9183
class Demo::ForexRateProvider
  EUR_PER_USD = BigDecimal("0.92")

  def call(from:, to:, date:)
    case [ from, to ]
    when %w[USD EUR] then eur_per_usd(date)
    when %w[EUR USD] then (1 / eur_per_usd(date)).round(4)
    end
  end

  private

  # A slow wave of a couple of percent either way, a cycle about every six months.
  def eur_per_usd(date)
    (EUR_PER_USD * (1 + BigDecimal(Math.sin(date.jd / 30.0).to_s) / 50)).round(4)
  end
end
