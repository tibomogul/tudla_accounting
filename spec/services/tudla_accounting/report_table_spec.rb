require "rails_helper"

RSpec.describe TudlaAccounting::Reports::Table do
  it "writes amounts as plain numbers, dates as ISO 8601, and formula-like text as text" do
    table = described_class.new([
      [ "Name", "Amount", "Date", "Count" ],
      [ "=SUM(A1:A9)", Money.new(-1_234_50, "AUD"), Date.new(2026, 3, 1), 3 ],
      [ "-Discounts", Money.new(5, "USD"), Time.zone.local(2026, 3, 1, 12), nil ],
      [ "@cmd", nil, nil, BigDecimal("12.5") ],
      [ "\tTabbed", nil, nil, nil ],
      [ "Plain - text", nil, nil, nil ]
    ])
    expect(CSV.parse(table.to_csv)).to eq([
      [ "Name", "Amount", "Date", "Count" ],
      [ "'=SUM(A1:A9)", "-1234.50", "2026-03-01", "3" ],
      [ "'-Discounts", "0.05", "2026-03-01", nil ],
      [ "'@cmd", nil, nil, "12.5" ],
      [ "'\tTabbed", nil, nil, nil ],
      [ "Plain - text", nil, nil, nil ]
    ])
  end
end

RSpec.describe TudlaAccounting::Reports::Table, "#to_xlsx" do
  def read(bytes)
    Tempfile.create([ "table", ".xlsx" ]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      yield Roo::Excelx.new(file.path)
    end
  end

  it "writes a sheet of numbers, dates and text, never formulas, its headings and totals in bold" do
    table = described_class.new([
      [ "Name", "Amount", "Date", "Count" ],
      [ "=SUM(A1:A9)", Money.new(-1_234_50, "AUD"), Date.new(2026, 3, 1), 3 ],
      described_class.total([ "Total", Money.new(-1_234_50, "AUD"), nil, BigDecimal("12.5") ])
    ])

    read(table.to_xlsx("Profit and Loss [2026]: a very long name indeed")) do |workbook|
      expect(workbook.default_sheet).to eq("Profit and Loss  2026   a very ") # forbidden characters out, 31 at most
      expect(workbook.row(2)).to eq([ "=SUM(A1:A9)", -1234.5, Date.new(2026, 3, 1), 3 ])
      expect(workbook.formula?(2, 1)).to be_falsey
      expect([ workbook.celltype(2, 1), workbook.celltype(2, 2), workbook.celltype(2, 3) ]).to eq(%i[string float date])
      expect(workbook.row(3)).to eq([ "Total", -1234.5, nil, 12.5 ])
      expect([ workbook.font(1, 1).bold?, workbook.font(2, 1).bold?, workbook.font(3, 2).bold? ]).to eq([ true, false, true ])
      expect(workbook.excelx_format(2, 2)).to eq("#,##0.00")
    end
  end
end

RSpec.describe TudlaAccounting, ".xlsx?" do
  around do |example|
    TudlaAccounting.remove_instance_variable(:@xlsx) if TudlaAccounting.instance_variable_defined?(:@xlsx)
    example.run
  ensure
    TudlaAccounting.remove_instance_variable(:@xlsx) if TudlaAccounting.instance_variable_defined?(:@xlsx)
  end

  it "is true when caxlsx can be loaded, and false otherwise" do
    expect(TudlaAccounting.xlsx?).to be(true)
    TudlaAccounting.remove_instance_variable(:@xlsx)
    allow(TudlaAccounting).to receive(:require).with("caxlsx").and_raise(LoadError)
    expect(TudlaAccounting.xlsx?).to be(false)
  end
end
