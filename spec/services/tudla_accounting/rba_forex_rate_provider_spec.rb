require "rails_helper"

RSpec.describe TudlaAccounting::RbaForexRateProvider, type: :service do
  subject(:provider) { described_class.new(open: ->(_url) { file_fixture("rba_f11_2023-current.xls").open }) }

  def rate(from, to, date) = provider.call(from: from, to: to, date: date)

  it "quotes currencies per AUD, as the RBA publishes them" do
    expect(rate("AUD", "PHP", Date.new(2023, 6, 13))).to eq(BigDecimal("37.88"))
    expect(rate("AUD", "JPY", Date.new(2023, 7, 28))).to eq(BigDecimal("92.8"))
    expect(rate("AUD", "GBP", Date.new(2024, 3, 15))).to eq(BigDecimal("0.5155"))
  end

  it "inverts and crosses rates through AUD" do
    expect(rate("GBP", "AUD", Date.new(2024, 3, 15))).to be_within(BigDecimal("0.0001")).of(BigDecimal("1.9399"))
    expect(rate("USD", "JPY", Date.new(2023, 7, 28))).to be_within(BigDecimal("0.0001")).of(BigDecimal("139.1513"))
  end

  it "uses the latest earlier business day's rate on a weekend" do
    expect(rate("AUD", "GBP", Date.new(2024, 3, 17))).to eq(rate("AUD", "GBP", Date.new(2024, 3, 15)))
  end

  it "has no rate for an unknown currency or a date it does not cover" do
    expect(rate("AUD", "XXX", Date.new(2024, 3, 15))).to be_nil
    expect(rate("AUD", "USD", Date.new(2022, 12, 1))).to be_nil
  end

  it "picks the RBA file for the year" do
    expect(provider.url_for(1985)).to eq("https://www.rba.gov.au/statistics/tables/xls-hist/1983-1986.xls")
    expect(provider.url_for(2020)).to eq("https://www.rba.gov.au/statistics/tables/xls-hist/2018-2022.xls")
    expect(provider.url_for(2027)).to eq("https://www.rba.gov.au/statistics/tables/xls-hist/2023-current.xls")
    expect { provider.url_for(1980) }.to raise_error(ArgumentError, "The RBA has no exchange rates for 1980")
  end

  it "downloads each file once" do
    opened = 0
    counting = described_class.new(open: ->(_url) { opened += 1; file_fixture("rba_f11_2023-current.xls").open })
    counting.call(from: "AUD", to: "USD", date: Date.new(2024, 3, 15))
    counting.call(from: "AUD", to: "EUR", date: Date.new(2023, 3, 15))
    expect(opened).to eq(1)
  end

  it "rejects a file without the RBA header row" do
    blank = described_class.new(open: ->(_url) { StringIO.new(Spreadsheet::Workbook.new.tap { |book| book.create_worksheet }.then { |book| io = StringIO.new; book.write(io); io.string }) })
    expect { blank.call(from: "AUD", to: "USD", date: Date.new(2024, 3, 15)) }.to raise_error(ArgumentError, "Could not find the header row in the RBA file")
  end

  it "reads the URL by default" do
    expect(URI).to receive(:parse).with("https://www.rba.gov.au/statistics/tables/xls-hist/2023-current.xls")
      .and_return(double(open: file_fixture("rba_f11_2023-current.xls").open))
    expect(described_class.new.call(from: "AUD", to: "GBP", date: Date.new(2024, 3, 15))).to eq(BigDecimal("0.5155"))
  end
end
