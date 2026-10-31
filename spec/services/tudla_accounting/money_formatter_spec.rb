require "rails_helper"

require_relative "../../support/configuration"

RSpec.describe TudlaAccounting::MoneyFormatter do
  include_context "with isolated TudlaAccounting configuration"

  def money(cents, currency) = Money.new(cents, currency)

  describe ".number" do
    it "writes the number in the home currency's style, whatever the amount's currency" do
      expect(described_class.number(money(1_234_56, "EUR"), "AUD")).to eq("1,234.56")
      expect(described_class.number(money(-1_234_56, "AUD"), "EUR")).to eq("-1.234,56")
      expect(described_class.number(money(1_234, "JPY"), "CHF")).to eq("1'234")
    end
  end

  describe ".labelled" do
    it "marks the home currency with its symbol and any other with its code, sign first" do
      expect(described_class.labelled(money(1_234_56, "AUD"), "AUD")).to eq("$1,234.56")
      expect(described_class.labelled(money(-5_00, "AUD"), "AUD")).to eq("-$5.00")
      expect(described_class.labelled(money(1_234_56, "USD"), "AUD")).to eq("USD 1,234.56") # not another $
      expect(described_class.labelled(money(1_234_56, "EUR"), "EUR")).to eq("€1.234,56")
      expect(described_class.labelled(money(1_234_56, "AUD"), Money::Currency.new("EUR"))).to eq("AUD 1.234,56")
    end

    it "uses the code for a home currency with no symbol" do
      expect(described_class.labelled(money(1_234, "XTS"), "XTS")).to eq("XTS 1,234")
    end
  end

  describe "for an organization" do
    let(:organization) { create(:organization, currency: "AUD") }

    it "writes its amounts in its number format, or its currency's marks without one" do
      expect(described_class.labelled(money(1_234_56, "AUD"), organization)).to eq("$1,234.56")
      TudlaAccounting.configuration.number_format = ->(org) { org == organization ? :comma : nil }
      expect(described_class.number(money(-1_234_56, "EUR"), organization)).to eq("-1.234,56")
      expect(described_class.labelled(money(1_234_56, "AUD"), organization)).to eq("$1.234,56")
      expect(described_class.labelled(money(1_234_56, "USD"), organization)).to eq("USD 1.234,56")
      expect(described_class.number(money(1_234_56, "AUD"), create(:organization, currency: "AUD"))).to eq("1,234.56")
    end
  end
end
