require "rails_helper"

RSpec.describe TudlaAccounting::Detail, type: :model do
  it "builds from the factory" do
    expect(build(:tudla_accounting_detail)).to be_valid
  end

  describe "enums" do
    it "maps tally to debit/credit integers" do
      expect(TudlaAccounting::Detail.tallies).to eq("debit" => 0, "credit" => 1)
    end
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:organization).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:entry).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:account).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:balance).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:foreign_exchange).macro).to eq(:has_one) }
    it { expect(described_class.reflect_on_association(:carrying_amount).macro).to eq(:has_one) }
  end

  describe "scopes" do
    it "filters by debit/credit" do
      org = create(:organization)
      asset = create(:tudla_accounting_account, category: :asset, organization: org)
      liability = create(:tudla_accounting_account, category: :liability, organization: org)
      entry = create(:tudla_accounting_entry, organization: org).tap do |e|
        e.details.create!(account: asset, tally: :debit, amount_cents: 1_000, currency: "USD", organization: org)
        e.details.create!(account: liability, tally: :credit, amount_cents: 1_000, currency: "USD", organization: org)
      end
      expect(entry.details.debits.count).to eq(1)
      expect(entry.details.credits.count).to eq(1)
    end
  end
end
