# frozen_string_literal: true

require "open-uri"

module TudlaAccounting
  # Exchange rates from the Reserve Bank of Australia's historical F11 tables
  # (https://www.rba.gov.au/statistics/historical-data.html), which quote each currency
  # per 1 AUD. Rates between two other currencies go through AUD. The RBA publishes on
  # business days only, so a weekend or holiday uses the latest earlier rate within a week.
  #
  #   TudlaAccounting.configure { |config| config.forex_rate_provider = TudlaAccounting::RbaForexRateProvider.new }
  #
  # Needs the `spreadsheet` gem in the host app, and network access to download the file.
  class RbaForexRateProvider
    BASE_URL = "https://www.rba.gov.au/statistics/tables/xls-hist"
    PERIODS = [ 1983..1986, 1987..1990, 1991..1994, 1995..1998, 1999..2002, 2003..2006,
                2007..2009, 2010..2013, 2014..2017, 2018..2022 ].freeze
    LOOKBACK_DAYS = 7

    # open: how to read a URL (overridable for tests or caching).
    def initialize(open: ->(url) { URI.parse(url).open })
      require "spreadsheet"
      @open = open
      @tables = {}
    end

    def call(from:, to:, date:)
      from_per_aud = per_aud(from, date)
      to_per_aud = per_aud(to, date)
      to_per_aud / from_per_aud if from_per_aud && to_per_aud
    end

    def url_for(year)
      period = PERIODS.find { |years| years.cover?(year) }
      return "#{BASE_URL}/#{period.first}-#{period.last}.xls" if period
      return "#{BASE_URL}/2023-current.xls" if year >= 2023

      raise ArgumentError, "The RBA has no exchange rates for #{year}"
    end

    private

    def per_aud(currency, date)
      return BigDecimal("1") if currency == "AUD"

      LOOKBACK_DAYS.times do |back|
        day = date - back
        rate = table(day.year)[:rates][day]&.dig(currency)
        return rate if rate
      end
      nil
    end

    # { rates: { date => { "USD" => rate, ... } } } for the file covering a year.
    def table(year)
      url = url_for(year)
      @tables[url] ||= parse(@open.call(url))
    end

    def parse(io)
      sheet = Spreadsheet.open(io).worksheet(0)
      header_index = sheet.each_with_index.find { |row, _| row[0].to_s.strip == "Units" }&.last
      raise ArgumentError, "Could not find the header row in the RBA file" unless header_index

      columns = sheet.row(header_index).each_with_index.filter_map { |cell, index| [ cell.to_s.strip, index ] if cell.to_s.strip.match?(/\A[A-Z]{3}\z/) }.to_h
      rates = {}
      sheet.each(header_index + 1) do |row|
        day = row_date(row[0])
        next unless day

        rates[day] = columns.filter_map { |currency, index| [ currency, BigDecimal(row[index].to_s) ] if row[index].is_a?(Numeric) && row[index].positive? }.to_h
      end
      { rates: rates }
    end

    def row_date(value)
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

      Date.parse(value.to_s) if value.is_a?(String)
    rescue Date::Error
      nil
    end
  end
end
