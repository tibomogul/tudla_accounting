require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe TudlaAccounting::IsAccountPayableChecker, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization) }
  let(:payable_account) { create(:tudla_accounting_account, code: "2100", category: :liability, organization: organization) }

  before { TudlaAccounting.configuration.payable_account_code = "2100" }

  def detail_on(account) = build(:tudla_accounting_detail, account: account, organization: organization)

  describe ".call" do
    it "returns true for the configured account" do
      expect(described_class.call(detail: detail_on(payable_account))).to be(true)
    end

    it "returns true for accounts beneath the configured account" do
      child = create(:tudla_accounting_account, code: "2105", category: :liability, organization: organization, parent: payable_account)
      grandchild = create(:tudla_accounting_account, code: "2106", category: :liability, organization: organization, parent: child)

      expect(described_class.call(detail: detail_on(child))).to be(true)
      expect(described_class.call(detail: detail_on(grandchild))).to be(true)
    end

    it "returns false for an account outside the configured account's tree, even with a similar code" do
      payable_account
      lookalike = create(:tudla_accounting_account, code: "2150", category: :liability, organization: organization)
      expect(described_class.call(detail: detail_on(lookalike))).to be(false)
    end

    it "returns false when no payable account code is configured" do
      TudlaAccounting.configuration.payable_account_code = nil
      expect(described_class.call(detail: detail_on(payable_account))).to be(false)
    end

    it "returns false when the detail has no account" do
      expect(described_class.call(detail: detail_on(nil))).to be(false)
    end

    it "returns false when the account code is nil" do
      expect(described_class.call(detail: detail_on(build(:tudla_accounting_account, code: nil)))).to be(false)
    end

    it "returns false when the detail is nil" do
      expect(described_class.call(detail: nil)).to be(false)
    end
  end
end
