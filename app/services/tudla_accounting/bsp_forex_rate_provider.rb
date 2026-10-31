# frozen_string_literal: true

require "open-uri"
require "roo"

module TudlaAccounting
  # Exchange rates from the Bangko Sentral ng Pilipinas (https://www.bsp.gov.ph/SitePages/Statistics/ExchangeRate.aspx),
  # which quotes currencies in pesos per unit. Rates between two other currencies go
  # through PHP. A weekend or holiday uses the latest earlier rate within a week.
  #
  #   TudlaAccounting.configure { |config| config.forex_rate_provider = TudlaAccounting::BspForexRateProvider.new }
  #
  # For each day it reads, cheapest first: the day's Reference Exchange Rate Bulletin (32
  # currencies, today only); the bulletins BspRatesJob has stored (ForexRate rows to PHP);
  # the daily peso–dollar rates (to yesterday); and the daily cross rates (31 currencies
  # since 1978, which the BSP brings up to date about monthly). Scheduling BspRatesJob for
  # each business day keeps every currency's rate from then on, not only the dollar's.
  #
  # Each file is downloaded when first needed and again after refresh_after. A file it
  # can't download counts as having no rate (logged), so the forms ask for one; one whose
  # layout it doesn't recognise raises ArgumentError. Needs network access to bsp.gov.ph.
  class BspForexRateProvider
    BASE_URL = "https://www.bsp.gov.ph"
    BULLETIN_URL = "#{BASE_URL}/Statistics/RERB/RERB.xlsx".freeze
    PESO_DOLLAR_URL = "#{BASE_URL}/statistics/external/pesodollar.xlsx".freeze
    CROSS_RATES_URL = "#{BASE_URL}/statistics/external/dailycrossrates.xlsx".freeze
    LOOKBACK_DAYS = 7
    NETWORK_ERRORS = [ OpenURI::HTTPError, SocketError, Timeout::Error, SystemCallError ].freeze
    # The cross rates' currency names (their two header rows, joined).
    NAMES = {
      "US dollar" => "USD", "Japanese yen" => "JPY", "Pound sterling" => "GBP", "Hongkong dollar" => "HKD", "Swiss franc" => "CHF",
      "Canadian dollar" => "CAD", "Singapore dollar" => "SGD", "Australian dollar" => "AUD", "Bahrain dinar" => "BHD", "Saudi riyal" => "SAR",
      "Brunei dollar" => "BND", "Indonesian rupiah" => "IDR", "Thai baht" => "THB", "UAE dirham" => "AED", "Euro" => "EUR", "S.Korean won" => "KRW",
      "Chinese yuan" => "CNY", "Argentinian peso" => "ARS", "Brazilian real" => "BRL", "Danish kroner" => "DKK", "Indian rupee" => "INR",
      "Malaysian ringgit" => "MYR", "Mexican new peso" => "MXN", "New Zealand dollar" => "NZD", "Norwegian kroner" => "NOK", "Pakistani rupee" => "PKR",
      "S.African rand" => "ZAR", "Swedish kroner" => "SEK", "Syrian pound" => "SYP", "New Taiwan dollar" => "TWD", "Venezuelan bolivar" => "VES"
    }.freeze
    # Currencies the cross rates quote in an older unit before these dates.
    SINCE = { "ARS" => Date.new(1992, 1, 1), "MXN" => Date.new(1993, 1, 1), "VES" => Date.new(2018, 8, 20) }.freeze
    MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze

    # open: how to read a URL (overridable for tests or caching); refresh_after: how long a
    # downloaded file is kept before it is read again.
    def initialize(open: ->(url) { URI.parse(url).open(open_timeout: 10, read_timeout: 60) }, refresh_after: 1.hour)
      @open = open
      @refresh_after = refresh_after
      @files = {}
    end

    def call(from:, to:, date:)
      from_in_php = php_per(from, date)
      to_in_php = php_per(to, date)
      from_in_php / to_in_php if from_in_php && to_in_php
    end

    # Stores the day's bulletin as ForexRate rows (each currency to PHP, for its date),
    # leaving those already there; the number stored.
    def record_bulletin!
      bulletin = file(BULLETIN_URL) { |io| parse_bulletin(io) } or return 0

      bulletin[:rates].count do |currency, rate|
        day = { year: bulletin[:date].year, month: bulletin[:date].month, day: bulletin[:date].day }
        ForexRate.create_with(rate: rate).find_or_create_by!(from: currency, to: "PHP", **day).previously_new_record?
      end
    end

    private

    def php_per(currency, date)
      return BigDecimal("1") if currency == "PHP"

      LOOKBACK_DAYS.times do |back|
        rate = on(currency, date - back)
        return rate if rate
      end
      nil
    end

    # The day's rate from the cheapest source that has it.
    def on(currency, day)
      bulletin = file(BULLETIN_URL) { |io| parse_bulletin(io) }
      return bulletin[:rates][currency] if bulletin && bulletin[:date] == day # nil when it has none that day

      stored = ForexRate.find_by(from: currency, to: "PHP", year: day.year, month: day.month, day: day.day)&.rate
      return stored if stored

      dollar = file(PESO_DOLLAR_URL) { |io| parse_peso_dollar(io) } if currency == "USD"
      return dollar[:rates][day] if dollar && dollar[:covers].cover?(day) # nil on a day without a quote
      return if SINCE[currency] && day < SINCE[currency]

      file(CROSS_RATES_URL) { |io| parse_cross_rates(io) }&.dig(day, currency)
    end

    # A file's parsed contents, downloaded when first asked for and again after
    # refresh_after; nil (logged) when it can't be downloaded.
    def file(url)
      cached = @files[url]
      return cached[:value] if cached && Time.current - cached[:at] < @refresh_after

      value = yield @open.call(url)
      @files[url] = { value: value, at: Time.current }
      value
    rescue *NETWORK_ERRORS => e
      Rails.logger.warn("TudlaAccounting: couldn't download #{url} (#{e.message}); no BSP rates from it")
      @files[url] = { value: nil, at: Time.current }
      nil
    end

    def workbook(io) = Roo::Excelx.new(StringIO.new(io.read))

    # { date:, rates: { "USD" => pesos, ... } }
    def parse_bulletin(io)
      sheet = workbook(io).then { |book| book.sheet(book.sheets.first) }
      rows = rows(sheet)
      header = rows.find { |row| row.include?("SYMBOL") && row.include?("PHIL.PESO") }
      date = rows.lazy.filter_map { |row| row.compact.first.then { |cell| Date.strptime(cell, "%d %B %Y") if cell.is_a?(String) && cell.match?(/\A\d{1,2} [A-Za-z]+ \d{4}\z/) } }.first
      raise ArgumentError, "Could not find the header row in the BSP bulletin" unless header && date

      symbol, peso = header.index("SYMBOL"), header.index("PHIL.PESO")
      { date: date, rates: rows.filter_map { |row| [ row[symbol], number(row[peso]) ] if row[symbol].to_s.match?(/\A[A-Z]{3}\z/) && number(row[peso]) }.to_h }
    end

    # { rates: { date => pesos per dollar }, covers: first date..last date }, from the year
    # blocks of the "daily" sheet.
    def parse_peso_dollar(io)
      book = workbook(io)
      raise ArgumentError, "Could not find the daily sheet in the BSP peso-dollar file" unless book.sheets.include?("daily")

      sheet = book.sheet("daily")
      rates = {}
      year = months = nil
      rows(sheet).each do |row|
        if row.first.is_a?(Numeric) && row.first > 1900 && row.drop(1).compact.empty?
          year, months = row.first.to_i, nil
        elsif row.first == "Day"
          months = row.drop(1).map { |name| MONTHS.index(name.to_s)&.succ }
        elsif year && months && row.first.is_a?(Numeric)
          months.each_with_index do |month, column|
            rate = number(row[column + 1])
            rates[Date.new(year, month, row.first.to_i)] = rate if month && rate && Date.valid_date?(year, month, row.first.to_i)
          end
        end
      end
      raise ArgumentError, "Could not find any rates in the BSP peso-dollar file" if rates.empty?

      { rates: rates, covers: rates.keys.min..rates.keys.max }
    end

    # { date => { "USD" => pesos, ... } }, from the "peso cross daily" sheet.
    def parse_cross_rates(io)
      book = workbook(io)
      sheet = book.sheet("peso cross daily") if book.sheets.include?("peso cross daily")
      rows = sheet ? rows(sheet) : []
      header = rows.index { |row| row.first == "Period" }
      raise ArgumentError, "Could not find the header row in the BSP cross rates file" unless header

      names = rows[header].zip(rows[header + 1]).map { |words| words.compact.join(" ").squish }
      columns = names.each_with_index.filter_map { |name, index| [ NAMES[name], index ] if NAMES[name] }
      rows.drop(header + 2).each_with_object({}) do |row, rates|
        next unless row.first.is_a?(Date)

        rates[row.first] = columns.filter_map { |currency, column| [ currency, number(row[column]) ] if number(row[column]) }.to_h
      end
    end

    def rows(sheet) = sheet.first_row ? (sheet.first_row..sheet.last_row).map { |index| sheet.row(index) } : []

    # A rate, or nil for the files' marks for none ("..", "-", "…", "N/A").
    def number(value)
      BigDecimal(value.to_s) if value.is_a?(Numeric) && value.positive?
    end
  end
end
