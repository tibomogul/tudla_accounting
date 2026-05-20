require "rails_helper"

RSpec.describe TudlaAccounting::Entry, type: :model do
  describe "validations" do
    it "requires particulars" do
      entry = build(:tudla_accounting_entry, particulars: nil)
      org = entry.organization
      asset = create(:tudla_accounting_account, category: :asset, organization: org)
      liability = create(:tudla_accounting_account, category: :liability, organization: org)
      entry.details.build(account: asset, tally: :debit, amount_cents: 1_000, currency: "USD", organization: org)
      entry.details.build(account: liability, tally: :credit, amount_cents: 1_000, currency: "USD", organization: org)
      entry.valid?
      expect(entry.errors[:particulars]).to be_present
    end

    it "is invalid without balanced debit/credit details" do
      org = create(:organization)
      asset = create(:tudla_accounting_account, category: :asset, organization: org)
      liability = create(:tudla_accounting_account, category: :liability, organization: org)
      entry = build(:tudla_accounting_entry, organization: org)
      entry.details.build(account: asset, tally: :debit, amount_cents: 10_000, currency: "USD", organization: org)
      entry.details.build(account: liability, tally: :credit, amount_cents: 5_000, currency: "USD", organization: org)
      expect(entry).not_to be_valid
      expect(entry.errors[:base]).to include("The credit and debit amounts are not equal")
    end

    it "is valid with balanced debit and credit details in the same currency" do
      org = create(:organization)
      asset = create(:tudla_accounting_account, category: :asset, organization: org)
      liability = create(:tudla_accounting_account, category: :liability, organization: org)
      entry = build(:tudla_accounting_entry, organization: org)
      entry.details.build(account: asset, tally: :debit, amount_cents: 10_000, currency: "USD", organization: org)
      entry.details.build(account: liability, tally: :credit, amount_cents: 10_000, currency: "USD", organization: org)
      expect(entry).to be_valid
    end
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:organization).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:source).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:related).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:details).macro).to eq(:has_many) }
  end
end
