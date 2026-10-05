require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe TudlaAccounting::IsAccountReceivableChecker, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization) }
  let(:receivable_account) { create(:tudla_accounting_account, code: "1100", category: :asset, organization: organization) }

  before { TudlaAccounting.configuration.receivable_account_code = "1100" }

  def detail_on(account) = build(:tudla_accounting_detail, account: account, organization: organization)

  describe ".call" do
    it "returns true for the configured account" do
      expect(described_class.call(detail: detail_on(receivable_account))).to be(true)
    end

    it "returns true for accounts beneath the configured account" do
      child = create(:tudla_accounting_account, code: "1105", category: :asset, organization: organization, parent: receivable_account)
      grandchild = create(:tudla_accounting_account, code: "1106", category: :asset, organization: organization, parent: child)

      expect(described_class.call(detail: detail_on(child))).to be(true)
      expect(described_class.call(detail: detail_on(grandchild))).to be(true)
    end

    it "returns false for an account outside the configured account's tree, even with a similar code" do
      receivable_account
      lookalike = create(:tudla_accounting_account, code: "1150", category: :asset, organization: organization)
      expect(described_class.call(detail: detail_on(lookalike))).to be(false)
    end

    it "returns false when no receivable account code is configured" do
      TudlaAccounting.configuration.receivable_account_code = nil
      expect(described_class.call(detail: detail_on(receivable_account))).to be(false)
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
