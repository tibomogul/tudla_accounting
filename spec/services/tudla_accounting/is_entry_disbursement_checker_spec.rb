require "rails_helper"

RSpec.describe TudlaAccounting::IsEntryDisbursementChecker, type: :service do
  describe ".call" do
    it "returns true when the entry source_type is Disbursement" do
      entry = create(:tudla_accounting_entry, source_type: "Disbursement")
      expect(described_class.call(entry: entry)).to be(true)
    end

    it "returns false when the entry source_type is something else" do
      entry = create(:tudla_accounting_entry, source_type: "Other")
      expect(described_class.call(entry: entry)).to be(false)
    end

    it "returns false when the entry has no source_type" do
      entry = build(:tudla_accounting_entry, source_type: nil)
      expect(described_class.call(entry: entry)).to be(false)
    end

    it "returns false when the entry is nil" do
      expect(described_class.call(entry: nil)).to be(false)
    end
  end
end
