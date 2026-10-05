require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe TudlaAccounting::CarryingAmountRole, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  def role_for(source_type) = described_class.call(entry: build(:tudla_accounting_entry, source_type: source_type))

  context "when sources are configured" do
    before do
      TudlaAccounting.configuration.carrying_amount_sources = {
        "SalesInvoice" => :receivable, "SupplierBill" => :payable, "CustomerReceipt" => :receipt, "VendorPayment" => :disbursement
      }
    end

    it "returns the role mapped to the entry's source_type" do
      expect(role_for("SalesInvoice")).to eq(:receivable)
      expect(role_for("SupplierBill")).to eq(:payable)
      expect(role_for("CustomerReceipt")).to eq(:receipt)
      expect(role_for("VendorPayment")).to eq(:disbursement)
    end

    it "returns nil for an unmapped or missing source_type" do
      expect(role_for("Invoice")).to be_nil
      expect(role_for(nil)).to be_nil
    end

    it "returns nil for a nil entry" do
      expect(described_class.call(entry: nil)).to be_nil
    end
  end

  it "returns nil when nothing is configured" do
    expect(role_for("Invoice")).to be_nil
  end
end
