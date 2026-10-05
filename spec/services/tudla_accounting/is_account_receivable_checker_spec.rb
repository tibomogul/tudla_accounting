require "rails_helper"

RSpec.describe TudlaAccounting::IsAccountReceivableChecker, type: :service do
  describe ".call" do
    it "returns true when the detail's account code starts with 11" do
      detail = create(:tudla_accounting_detail, account: create(:tudla_accounting_account, code: "1100"))
      expect(described_class.call(detail: detail)).to be(true)
    end

    it "returns false for any other account code" do
      detail = create(:tudla_accounting_detail, account: create(:tudla_accounting_account, code: "4000"))
      expect(described_class.call(detail: detail)).to be(false)
    end

    it "returns false when the detail has no account" do
      detail = build(:tudla_accounting_detail, account: nil)
      expect(described_class.call(detail: detail)).to be(false)
    end

    it "returns false when the account code is nil" do
      detail = build(:tudla_accounting_detail, account: build(:tudla_accounting_account, code: nil))
      expect(described_class.call(detail: detail)).to be(false)
    end

    it "returns false when the detail is nil" do
      expect(described_class.call(detail: nil)).to be(false)
    end
  end
end
