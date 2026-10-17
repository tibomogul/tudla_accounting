require "rails_helper"

RSpec.describe TudlaAccounting::IsAccountPayableChecker, type: :service do
  let(:organization) { create(:organization) }
  let(:payable_account) { create(:tudla_accounting_account, code: "2100", category: :liability, organization: organization, role: :payable) }

  def detail_on(account) = build(:tudla_accounting_detail, account: account, organization: organization)

  describe ".call" do
    it "returns true for the account marked payable" do
      expect(described_class.call(detail: detail_on(payable_account))).to be(true)
    end

    it "returns true for accounts beneath it" do
      child = create(:tudla_accounting_account, code: "2105", category: :liability, organization: organization, parent: payable_account)
      grandchild = create(:tudla_accounting_account, code: "2106", category: :liability, organization: organization, parent: child)

      expect(described_class.call(detail: detail_on(child))).to be(true)
      expect(described_class.call(detail: detail_on(grandchild))).to be(true)
    end

    it "returns false for an account outside its tree, even with a similar code" do
      payable_account
      lookalike = create(:tudla_accounting_account, code: "2150", category: :liability, organization: organization)
      expect(described_class.call(detail: detail_on(lookalike))).to be(false)
    end

    # Posting loads its accounts before taking the posting lock, under which roles change.
    it "goes by the role in the database, not on an account loaded before it changed" do
      loaded = create(:tudla_accounting_account, code: "2100", category: :liability, organization: organization)
      TudlaAccounting::AccountRoleAssigner.save!(TudlaAccounting::Account.find(loaded.id), :payable)
      expect(described_class.call(detail: detail_on(loaded))).to be(true)

      TudlaAccounting::AccountRoleAssigner.save!(TudlaAccounting::Account.find(loaded.id), nil)
      expect(described_class.call(detail: detail_on(loaded.tap { |account| account.role = "payable" }))).to be(false)
    end

    it "returns false when no account is marked payable" do
      TudlaAccounting::AccountRoleAssigner.save!(payable_account, nil)
      expect(described_class.call(detail: detail_on(payable_account))).to be(false)
    end

    it "goes by the role, not the code: another organization's 2100 isn't one, and a renumbered one still is" do
      other = create(:organization)
      lookalike = create(:tudla_accounting_account, code: "2100", category: :liability, organization: other)
      expect(described_class.call(detail: build(:tudla_accounting_detail, account: lookalike, organization: other))).to be(false)

      payable_account.update!(code: "2150")
      expect(described_class.call(detail: detail_on(payable_account))).to be(true)
    end

    it "returns false when the detail has no account" do
      expect(described_class.call(detail: detail_on(nil))).to be(false)
    end

    it "returns false when the detail is nil" do
      expect(described_class.call(detail: nil)).to be(false)
    end
  end

  describe "#call" do
    # CarryingAmountProcessor checks every line of an entry, and of the entry it's related to.
    it "looks the role up once for several lines" do
      child = create(:tudla_accounting_account, code: "2105", category: payable_account.category, organization: organization, parent: payable_account)
      lookalike = create(:tudla_accounting_account, code: "2150", category: payable_account.category, organization: organization)
      details = [ payable_account, child, lookalike, nil ].map { |account| detail_on(account) }
      checker = described_class.new(organization)

      queries = 0
      count = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
      results = ActiveSupport::Notifications.subscribed(count, "sql.active_record") { details.map { |detail| checker.call(detail: detail) } }

      expect(results).to eq([ true, true, false, false ])
      expect(queries).to eq(0)
    end

    it "finds nothing when no account has the role" do
      account = create(:tudla_accounting_account, code: "2100", category: :liability, organization: organization)
      expect(described_class.new(organization).call(detail: detail_on(account))).to be(false)
    end
  end
end
