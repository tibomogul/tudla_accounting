require "rails_helper"

RSpec.describe TudlaAccounting::Configuration do
  subject(:config) { described_class.new }

  it "leaves carrying amounts unconfigured by default" do
    expect(config).to have_attributes(receivable_account_code: nil, payable_account_code: nil,
                                      carrying_amount_sources: {}, due_date_method: :due_date)
  end

  describe "#carrying_amount_sources=" do
    it "normalizes class names to strings and roles to symbols" do
      config.carrying_amount_sources = { SalesInvoice: "receivable", "VendorPayment" => :disbursement }
      expect(config.carrying_amount_sources).to eq("SalesInvoice" => :receivable, "VendorPayment" => :disbursement)
    end

    it "rejects unknown roles" do
      expect { config.carrying_amount_sources = { "Invoice" => :recievable } }
        .to raise_error(ArgumentError, /unknown carrying amount role :recievable for Invoice/)
    end
  end

  describe "#dup" do
    it "copies the entry source registry, so the copy can change without affecting the original" do
      config.entry_sources["Invoice"] = ->(_record) { {} }
      copy = config.dup
      copy.entry_sources["Bill"] = ->(_record) { {} }

      expect(config.entry_sources.keys).to eq([ "Invoice" ])
      expect(copy.entry_sources.keys).to eq([ "Invoice", "Bill" ])
    end
  end
end
