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
