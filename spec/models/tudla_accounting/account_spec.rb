require "rails_helper"

RSpec.describe TudlaAccounting::Account, type: :model do
  it "builds from the factory" do
    expect(build(:tudla_accounting_account)).to be_valid
  end

  describe "validations" do
    it "requires name, code, and category" do
      account = TudlaAccounting::Account.new
      account.valid?
      expect(account.errors[:name]).to be_present
      expect(account.errors[:code]).to be_present
      expect(account.errors[:category]).to be_present
    end

    it "rejects a child with a different category than its parent" do
      parent = create(:tudla_accounting_account, category: :asset)
      child = build(:tudla_accounting_account, category: :liability, parent: parent, organization: parent.organization)
      expect(child).not_to be_valid
      expect(child.errors[:base]).to include("Attributes are not compatible with parent")
    end
  end

  describe "enums" do
    it "maps categories to expected integers" do
      expect(TudlaAccounting::Account.categories).to eq(
        "asset" => 0,
        "liability" => 1,
        "equity" => 2,
        "income" => 3,
        "expense" => 4
      )
    end
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:organization).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:balances).macro).to eq(:has_many) }
    it { expect(described_class.reflect_on_association(:details).macro).to eq(:has_many) }
    it { expect(described_class.reflect_on_association(:entries).macro).to eq(:has_many) }
    it { expect(described_class.reflect_on_association(:contra_account).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:contra_for).macro).to eq(:has_one) }
    it { expect(described_class.reflect_on_association(:bank_account_balance).macro).to eq(:has_one) }
  end

  describe "#debit_balance?" do
    it "returns true for asset and expense accounts" do
      expect(build(:tudla_accounting_account, category: :asset).debit_balance?).to be true
      expect(build(:tudla_accounting_account, category: :expense).debit_balance?).to be true
    end

    it "returns false for liability, equity, and income accounts" do
      expect(build(:tudla_accounting_account, category: :liability).debit_balance?).to be false
      expect(build(:tudla_accounting_account, category: :equity).debit_balance?).to be false
      expect(build(:tudla_accounting_account, category: :income).debit_balance?).to be false
    end
  end
end
