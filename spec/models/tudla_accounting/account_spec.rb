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

  describe "#balance_sheet_account?" do
    it "is true for assets, liabilities and equity, and false for income and expenses" do
      results = TudlaAccounting::Account.categories.keys.to_h { |category| [ category, build(:tudla_accounting_account, category: category).balance_sheet_account? ] }
      expect(results).to eq("asset" => true, "liability" => true, "equity" => true, "income" => false, "expense" => false)
    end
  end

  describe "#code_with_name" do
    it "joins the code and name" do
      expect(build(:tudla_accounting_account, code: "1100", name: "Accounts Receivable").code_with_name).to eq("1100 - Accounts Receivable")
    end
  end

  describe "rules for the chart of accounts" do
    let(:organization) { create(:organization) }
    let(:equipment) { create(:tudla_accounting_account, code: "1500", category: :asset, organization: organization) }
    let(:capital) { create(:tudla_accounting_account, code: "3000", category: :equity, organization: organization) }
    let(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

    def post_to(account)
      entry = build(:tudla_accounting_entry, organization: organization, transacted_at: Time.zone.local(2026, 2, 1))
      entry.details.build(account: account, tally: :debit, amount_cents: 100, currency: "USD", organization: organization)
      entry.details.build(account: capital, tally: :credit, amount_cents: 100, currency: "USD", organization: organization)
      entry.save!
      year
      entry.post(entry.transacted_at)
    end

    it "keeps codes unique within an organization only" do
      equipment
      expect(build(:tudla_accounting_account, code: "1500", organization: organization)).not_to be_valid
      expect(build(:tudla_accounting_account, code: "1500", organization: create(:organization))).to be_valid
    end

    it "accepts known currency codes, upper-casing them" do
      expect(build(:tudla_accounting_account, currency: " eur ")).to be_valid.and(have_attributes(currency: "EUR"))
      expect(build(:tudla_accounting_account, currency: "")).to be_valid.and(have_attributes(currency: nil))
      expect(build(:tudla_accounting_account, currency: "XYZ").tap(&:validate).errors[:currency]).to eq([ "is not a known currency code" ])
    end

    it "fixes the category, parent and contra account once there are postings" do
      expect(equipment.structure_editable?).to be(true)
      post_to(equipment)

      expect(equipment.reload.structure_editable?).to be(false)
      expect(equipment.update(category: :expense)).to be(false)
      expect(equipment.errors[:base]).to include("Category, parent and contra account can't change once the account has postings")
      expect(equipment.reload.update(name: "Plant")).to be(true)
    end

    it "can only be deleted with no postings, sub-accounts or contra accounts" do
      child = create(:tudla_accounting_account, category: :asset, organization: organization, parent: equipment)
      contra = create(:tudla_accounting_account, category: :asset, organization: organization, contra_account: equipment)

      expect([ equipment, child, contra ].map(&:deletable?)).to eq([ false, true, true ])
      expect(equipment.destroy).to be(false)
      expect(equipment.errors[:base]).to eq([ "Only an account with no postings, sub-accounts or contra accounts can be deleted" ])

      post_to(child)
      expect(child.reload.deletable?).to be(false)
      expect(contra.destroy).to be_truthy
    end
  end
end
