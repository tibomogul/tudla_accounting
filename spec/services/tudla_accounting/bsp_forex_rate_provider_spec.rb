require "rails_helper"

RSpec.describe TudlaAccounting::BspForexRateProvider, type: :service do
  include ActiveSupport::Testing::TimeHelpers

  # Trimmed from the BSP's files of 30 Oct 2026: the bulletin of that day, the peso–dollar
  # rates of 2025 and 2026 (to 30 Oct), and the cross rates of a few days in 1991–92 and
  # 2018 and 14–30 Sep 2026.
  FIXTURES = {
    described_class::BULLETIN_URL => "bsp_rerb.xlsx",
    described_class::PESO_DOLLAR_URL => "bsp_pesodollar.xlsx",
    described_class::CROSS_RATES_URL => "bsp_dailycrossrates.xlsx"
  }.freeze

  let(:opened) { [] }
  let(:files) { FIXTURES.transform_values { |name| -> { file_fixture(name).open } } }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:open) { ->(url) { opened << url; files.fetch(url).call } }
  subject(:provider) { described_class.new(open: open, cache: cache) }

  def rate(from, to, date) = provider.call(from: from, to: to, date: date)
  def empty_workbook = StringIO.new(Axlsx::Package.new.tap { |package| package.workbook.add_worksheet(name: "Sheet1") }.to_stream.read)

  it "quotes currencies in pesos from the day's bulletin, without the larger files" do
    expect(rate("USD", "PHP", Date.new(2026, 10, 30))).to eq(BigDecimal("63.852"))
    expect(rate("EUR", "PHP", Date.new(2026, 10, 30))).to eq(BigDecimal("71.3865"))
    expect(opened).to eq([ described_class::BULLETIN_URL ])
    expect(rate("KWD", "PHP", Date.new(2026, 10, 30))).to be_nil # N/A that day, nor in the week before
  end

  it "quotes the dollar on earlier days from the peso–dollar rates, the latest earlier one on a weekend" do
    expect(rate("USD", "PHP", Date.new(2026, 10, 12))).to eq(BigDecimal("62.793"))
    expect(rate("USD", "PHP", Date.new(2026, 10, 4))).to eq(BigDecimal("62.748")) # Sunday: Friday's
    expect(rate("USD", "PHP", Date.new(2025, 1, 31))).to eq(BigDecimal("58.362")) # last year's
    expect(opened).not_to include(described_class::CROSS_RATES_URL)
  end

  it "quotes other currencies from the cross rates, and crosses and inverts them through the peso" do
    expect(rate("GBP", "PHP", Date.new(2026, 9, 30))).to eq(BigDecimal("82.6614"))
    expect(rate("GBP", "PHP", Date.new(2026, 9, 27))).to eq(BigDecimal("82.9446")) # Sunday: Friday's
    expect(rate("EUR", "USD", Date.new(2026, 9, 30))).to eq(BigDecimal("70.8892") / BigDecimal("62.485"))
    expect(rate("PHP", "JPY", Date.new(2026, 9, 30))).to eq(1 / BigDecimal("0.3973"))
    expect(rate("PHP", "PHP", Date.new(2026, 9, 30))).to eq(1)
  end

  it "reads a redenominated currency only in its present unit" do
    expect(rate("ARS", "PHP", Date.new(1992, 1, 2))).to eq(BigDecimal("0.002665"))
    expect(rate("VES", "PHP", Date.new(2018, 8, 17))).to be_nil # bolívares fuertes
    expect(rate("VES", "PHP", Date.new(2018, 8, 20))).to eq(BigDecimal("0.0002"))
  end

  it "uses the bulletins BspRatesJob stored for the days after the cross rates end" do
    expect(rate("GBP", "PHP", Date.new(2026, 10, 15))).to be_nil
    TudlaAccounting::ForexRate.create!(from: "GBP", to: "PHP", year: 2026, month: 10, day: 15, rate: BigDecimal("84.1"))
    expect(rate("GBP", "PHP", Date.new(2026, 10, 15))).to eq(BigDecimal("84.1"))
    expect(rate("GBP", "USD", Date.new(2026, 10, 16))).to eq(BigDecimal("84.1") / BigDecimal("63.049")) # GBP stored for the day before
  end

  it "has no rate for an unknown currency or a date the files don't reach" do
    expect(rate("XXX", "PHP", Date.new(2026, 9, 30))).to be_nil
    expect(rate("USD", "PHP", Date.new(1970, 1, 1))).to be_nil
  end

  it "stores the day's bulletin once, as rates to the peso" do
    expect(provider.record_bulletin!).to eq(31) # 32 currencies, Kuwait's N/A
    expect(TudlaAccounting::ForexRate.find_by!(from: "USD", to: "PHP", year: 2026, month: 10, day: 30).rate).to eq(BigDecimal("63.852"))
    expect(provider.record_bulletin!).to eq(0)
  end

  it "downloads each file once, and again after refresh_after" do
    travel_to(Time.zone.local(2026, 10, 30, 12)) do
      rate("USD", "PHP", Date.new(2026, 10, 30))
      rate("EUR", "PHP", Date.new(2026, 10, 30))
      expect(opened).to eq([ described_class::BULLETIN_URL ])
      travel 61.minutes
      rate("USD", "PHP", Date.new(2026, 10, 30))
      expect(opened).to eq([ described_class::BULLETIN_URL ] * 2)
    end
  end

  it "keeps what it read in the cache, for other instances, until it's due to be read again" do
    travel_to(Time.zone.local(2026, 10, 30, 12)) do
      rate("GBP", "PHP", Date.new(2026, 9, 30))
      expect(opened).to eq([ described_class::BULLETIN_URL, described_class::CROSS_RATES_URL ])

      travel 2.hours
      other = described_class.new(open: open, cache: cache)
      expect(other.call(from: "GBP", to: "PHP", date: Date.new(2026, 9, 30))).to eq(BigDecimal("82.6614"))
      expect(opened.drop(2)).to eq([ described_class::BULLETIN_URL ]) # the bulletin is due again; the cross rates not for a day

      travel 23.hours
      provider.call(from: "GBP", to: "PHP", date: Date.new(2026, 9, 29))
      expect(opened.drop(3)).to eq([ described_class::BULLETIN_URL, described_class::CROSS_RATES_URL ])
    end

    uncached = described_class.new(open: open, cache: nil)
    expect { uncached.call(from: "USD", to: "PHP", date: Date.new(2026, 10, 30)) }.to change(opened, :size).by(1)
  end

  it "treats a file it can't download as having no rates, and logs it" do
    files[described_class::BULLETIN_URL] = -> { raise SocketError, "getaddrinfo: Name or service not known" }
    allow(Rails.logger).to receive(:warn)
    expect(rate("USD", "PHP", Date.new(2026, 10, 30))).to eq(BigDecimal("63.852")) # the peso–dollar rates have it too
    expect(provider.record_bulletin!).to eq(0)
    expect(cache.read([ "tudla_accounting/bsp_forex_rates", 1, described_class::BULLETIN_URL ])).to be_nil
    expect(Rails.logger).to have_received(:warn).with(%r{couldn't download https://www.bsp.gov.ph/Statistics/RERB/RERB.xlsx \(getaddrinfo})
  end

  it "rejects a file whose layout it doesn't recognise" do
    files[described_class::BULLETIN_URL] = -> { empty_workbook }
    expect { rate("USD", "PHP", Date.new(2026, 10, 30)) }.to raise_error(ArgumentError, "Could not find the header row in the BSP bulletin")
  end

  it "rejects peso–dollar and cross rates files it doesn't recognise" do
    files[described_class::PESO_DOLLAR_URL] = -> { empty_workbook }
    expect { rate("USD", "PHP", Date.new(2026, 10, 12)) }.to raise_error(ArgumentError, "Could not find the daily sheet in the BSP peso-dollar file")
    files[described_class::CROSS_RATES_URL] = -> { empty_workbook }
    expect { rate("GBP", "PHP", Date.new(2026, 9, 30)) }.to raise_error(ArgumentError, "Could not find the header row in the BSP cross rates file")

    blank_daily = Axlsx::Package.new.tap { |package| package.workbook.add_worksheet(name: "daily") { |sheet| sheet.add_row [ "Philippine Peso per US Dollar Rate" ] } }
    files[described_class::PESO_DOLLAR_URL] = -> { StringIO.new(blank_daily.to_stream.read) }
    expect { described_class.new(open: ->(url) { files.fetch(url).call }, cache: nil).call(from: "USD", to: "PHP", date: Date.new(2026, 10, 12)) }
      .to raise_error(ArgumentError, "Could not find any rates in the BSP peso-dollar file")
  end

  it "reads the URL by default, with timeouts, keeping what it read in Rails.cache" do
    expect(URI).to receive(:parse).with(described_class::BULLETIN_URL).and_return(double.tap { |uri|
      expect(uri).to receive(:open).with(open_timeout: 10, read_timeout: 60).and_return(file_fixture("bsp_rerb.xlsx").open)
    })
    expect(Rails.cache).to receive(:read).and_return(nil)
    expect(Rails.cache).to receive(:write)
    expect(described_class.new.call(from: "USD", to: "PHP", date: Date.new(2026, 10, 30))).to eq(BigDecimal("63.852"))
  end
end
