require "rails_helper"

RSpec.describe TudlaAccounting::AmountParser do
  describe ".decimal" do
    it "reads digits with a decimal point, thousands commas, and a sign or parentheses" do
      { "1234.5" => "1234.5", "1,234,567.89" => "1234567.89", " +3 " => "3", "-2.5" => "-2.5", "(5.00)" => "-5", ".5" => "0.5", "7." => "7" }.each do |typed, number|
        expect(described_class.decimal(typed)).to eq(BigDecimal(number)), typed
      end
      expect(described_class.decimal(12)).to eq(12)
      expect(described_class.decimal(0.1)).to eq(BigDecimal("0.1")) # a spreadsheet cell
      expect([ nil, "", "  " ].map { |blank| described_class.decimal(blank) }).to all(be_nil)
    end

    it "refuses anything else rather than read part of it" do
      [ "lots", "1.234,50", "10,00", "1,23,4", "1e3", "1_000", "$5", "5 AUD", "Infinity", "NaN", "(-5)", "--5", ".", "-", "1 000", "0x10" ].each do |typed|
        expect { described_class.decimal(typed) }.to raise_error(ArgumentError, "#{typed} isn't a number"), typed
      end
      expect { described_class.decimal(Float::INFINITY) }.to raise_error(ArgumentError)
    end
  end

  describe ".cents" do
    it "gives cents of the currency, refusing more decimal places than it has unless rounding" do
      expect(described_class.cents("1,234.50", "AUD")).to eq(1_234_50)
      expect(described_class.cents("(12)", "JPY")).to eq(-12)
      expect(described_class.cents("1.234", "BHD")).to eq(1_234)
      expect(described_class.cents("", "AUD")).to be_nil
      expect { described_class.cents("10.005", "AUD") }.to raise_error(ArgumentError, "10.005 has too many decimal places for AUD, which has 2")
      expect { described_class.cents("12.5", "JPY") }.to raise_error(ArgumentError, "12.5 has too many decimal places for JPY, which has none")
      expect { described_class.cents("lots", "AUD") }.to raise_error(ArgumentError, "lots isn't an amount")
      expect(described_class.cents("10.005", "AUD", round: true)).to eq(10_01)
      expect(described_class.cents(10.005, "AUD", round: true)).to eq(10_01)
      expect(described_class.cents("10.500", "AUD")).to eq(10_50) # trailing zeros are no extra places
    end
  end

  describe ".text" do
    it "writes an amount as it is read back, whatever the currency's own style" do
      expect([ Money.new(-1_234_567_89, "EUR"), Money.new(1_234_50, "CHF"), Money.new(1_234, "JPY"), Money.new(1_234, "BHD") ].map { |money| described_class.text(money) })
        .to eq([ "-1234567.89", "1234.50", "1234", "1.234" ])
    end
  end
end
