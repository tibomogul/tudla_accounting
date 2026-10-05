require "rails_helper"

RSpec.describe TudlaAccounting::Balance, type: :model do
  it "builds from the factory" do
    expect(build(:tudla_accounting_balance)).to be_valid
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:organization).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:account).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:period).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:details).macro).to eq(:has_many) }
  end

  describe "monetized fields" do
    it "exposes starting/current/ending amounts as Money objects" do
      balance = create(:tudla_accounting_balance, starting_amount_cents: 1_000, current_amount_cents: 2_000, ending_amount_cents: 3_000)
      expect(balance.starting_amount).to be_a(Money)
      expect(balance.current_amount).to be_a(Money)
      expect(balance.ending_amount).to be_a(Money)
      expect(balance.starting_amount.cents).to eq(1_000)
    end
  end

  describe "posting" do
    let(:organization) { create(:organization) }
    let(:asset) { create(:tudla_accounting_account, category: :asset, organization: organization) }
    let(:liability) { create(:tudla_accounting_account, category: :liability, organization: organization) }
    let(:year) { create(:tudla_accounting_period, organization: organization, from_date: Date.new(2026, 1, 1), thru_date: Date.new(2026, 12, 31).end_of_day) }
    let(:q1) { create(:tudla_accounting_period, organization: organization, parent: year, from_date: Date.new(2026, 1, 1), thru_date: Date.new(2026, 3, 31).end_of_day) }
    let(:q2) { create(:tudla_accounting_period, organization: organization, parent: year, from_date: Date.new(2026, 4, 1), thru_date: Date.new(2026, 6, 30).end_of_day) }
    let(:apr) { create(:tudla_accounting_period, organization: organization, parent: q2, from_date: Date.new(2026, 4, 1), thru_date: Date.new(2026, 4, 30).end_of_day) }
    let(:may) { create(:tudla_accounting_period, organization: organization, parent: q2, from_date: Date.new(2026, 5, 1), thru_date: Date.new(2026, 5, 31).end_of_day) }

    def usd(cents) = Money.new(cents, "USD")
    def balance_for(account, period) = described_class.find_by(account: account, period: period)

    describe "#update_current_amount" do
      it "adds debits to and subtracts credits from a debit-balance account" do
        balance = create(:tudla_accounting_balance, account: asset, period: year, organization: organization)
        balance.update_current_amount(usd(100_00), "debit")
        balance.update_current_amount(usd(30_00), "credit")
        expect(balance.reload).to have_attributes(current_amount: usd(70_00), ending_amount: usd(70_00), starting_amount: usd(0))
      end

      it "adds credits to and subtracts debits from a credit-balance account" do
        balance = create(:tudla_accounting_balance, account: liability, period: year, organization: organization)
        balance.update_current_amount(usd(100_00), "credit")
        balance.update_current_amount(usd(30_00), "debit")
        expect(balance.reload).to have_attributes(current_amount: usd(70_00), ending_amount: usd(70_00))
      end

      it "rejects non-Money amounts and unknown tallies" do
        balance = create(:tudla_accounting_balance, account: asset, period: year, organization: organization)
        expect { balance.update_current_amount(100, "debit") }.to raise_error(ArgumentError, "amount must be a Money object")
        expect { balance.update_current_amount(usd(1), "sideways") }.to raise_error(ArgumentError, "tally must be debit or credit")
      end
    end

    describe "#update_starting_amount" do
      it "moves the starting and ending amounts but not the current amount" do
        balance = create(:tudla_accounting_balance, account: asset, period: year, organization: organization)
        balance.update_starting_amount(usd(50_00), "debit")
        expect(balance.reload).to have_attributes(starting_amount: usd(50_00), current_amount: usd(0), ending_amount: usd(50_00))
      end

      it "follows the account's normal side for credits and credit-balance accounts" do
        asset_balance = create(:tudla_accounting_balance, account: asset, period: year, organization: organization)
        liability_balance = create(:tudla_accounting_balance, account: liability, period: year, organization: organization)

        asset_balance.update_starting_amount(usd(30_00), "credit")
        liability_balance.update_starting_amount(usd(100_00), "credit")
        liability_balance.update_starting_amount(usd(30_00), "debit")

        expect(asset_balance.reload).to have_attributes(starting_amount: usd(-30_00), ending_amount: usd(-30_00))
        expect(liability_balance.reload).to have_attributes(starting_amount: usd(70_00), current_amount: usd(0), ending_amount: usd(70_00))
      end

      it "rejects non-Money amounts and unknown tallies" do
        balance = create(:tudla_accounting_balance, account: asset, period: year, organization: organization)
        expect { balance.update_starting_amount(100, "debit") }.to raise_error(ArgumentError, "amount must be a Money object")
        expect { balance.update_starting_amount(usd(1), "sideways") }.to raise_error(ArgumentError, "tally must be debit or credit")
      end
    end

    describe "#post" do
      it "rejects non-Money amounts and unknown tallies" do
        balance = create(:tudla_accounting_balance, account: asset, period: year, organization: organization)
        expect { balance.post(100, "debit") }.to raise_error(ArgumentError, "amount must be a Money object")
        expect { balance.post(usd(1), "sideways") }.to raise_error(ArgumentError, "tally must be debit or credit")
      end

      it "rolls the amount up into balances for every ancestor period" do
        balance = create(:tudla_accounting_balance, account: asset, period: apr, organization: organization)
        expect { balance.post(usd(100_00), "debit") }.to change(described_class, :count).by(2) # Q2 and year

        expect(balance.reload.current_amount).to eq(usd(100_00))
        expect(balance_for(asset, q2).current_amount).to eq(usd(100_00))
        expect(balance_for(asset, year).current_amount).to eq(usd(100_00))
      end

      it "rolls the amount up into balances for every ancestor account" do
        root = create(:tudla_accounting_account, category: :asset, organization: organization)
        parent = create(:tudla_accounting_account, category: :asset, organization: organization, parent: root)
        child = create(:tudla_accounting_account, category: :asset, organization: organization, parent: parent)

        described_class.get(child, year).post(usd(100_00), "credit")

        [ child, parent, root ].each do |account|
          expect(balance_for(account, year).current_amount).to eq(usd(-100_00))
        end
      end

      it "carries the amount into the starting amount of later sibling periods and their children" do
        q2_balance = described_class.get(asset, q2)
        apr_balance = described_class.get(asset, apr)

        described_class.get(asset, q1).post(usd(100_00), "debit")

        expect(q2_balance.reload).to have_attributes(starting_amount: usd(100_00), current_amount: usd(0), ending_amount: usd(100_00))
        expect(apr_balance.reload).to have_attributes(starting_amount: usd(100_00), current_amount: usd(0), ending_amount: usd(100_00))
        expect(balance_for(asset, year).current_amount).to eq(usd(100_00))
      end
    end

    describe ".get" do
      it "returns the existing balance without creating another" do
        existing = described_class.get(asset, year)
        expect { expect(described_class.get(asset, year)).to eq(existing) }.not_to change(described_class, :count)
      end

      it "creates a zero balance in the organization's currency when there is nothing before it" do
        balance = described_class.get(asset, year)
        expect(balance).to be_persisted
        expect(balance).to have_attributes(starting_amount: usd(0), current_amount: usd(0), ending_amount: usd(0),
                                           currency: "USD", organization: organization)
      end

      it "starts from the ending amount of the closest earlier period at the same depth" do
        create(:tudla_accounting_balance, account: asset, period: apr, organization: organization,
                                          starting_amount_cents: 0, current_amount_cents: 200_00, ending_amount_cents: 200_00)

        expect(described_class.get(asset, may)).to have_attributes(starting_amount: usd(200_00), current_amount: usd(0), ending_amount: usd(200_00))
      end

      it "starts from the parent period's starting amount when it is the first child" do
        create(:tudla_accounting_balance, account: asset, period: q2, organization: organization,
                                          starting_amount_cents: 300_00, current_amount_cents: 0, ending_amount_cents: 300_00)

        expect(described_class.get(asset, apr).starting_amount).to eq(usd(300_00))
      end

      it "skips earlier periods that have no balance and starts from the latest one that does" do
        jan = create(:tudla_accounting_period, organization: organization, parent: q1, from_date: Date.new(2026, 1, 1), thru_date: Date.new(2026, 1, 31).end_of_day)
        create(:tudla_accounting_period, organization: organization, parent: q1, from_date: Date.new(2026, 2, 1), thru_date: Date.new(2026, 2, 28).end_of_day)
        mar = create(:tudla_accounting_period, organization: organization, parent: q1, from_date: Date.new(2026, 3, 1), thru_date: Date.new(2026, 3, 31).end_of_day)
        create(:tudla_accounting_balance, account: asset, period: jan, organization: organization,
                                          starting_amount_cents: 0, current_amount_cents: 100_00, ending_amount_cents: 100_00)

        expect(described_class.get(asset, mar)).to have_attributes(starting_amount: usd(100_00), ending_amount: usd(100_00))
      end

      it "opens a year with the previous year's closing balance, but only for balance-sheet accounts" do
        previous_year = create(:tudla_accounting_period, organization: organization, from_date: Date.new(2025, 1, 1), thru_date: Date.new(2025, 12, 31).end_of_day)
        income = create(:tudla_accounting_account, category: :income, organization: organization)
        [ asset, income ].each do |account|
          create(:tudla_accounting_balance, account: account, period: previous_year, organization: organization,
                                            starting_amount_cents: 0, current_amount_cents: 500_00, ending_amount_cents: 500_00)
        end

        expect(described_class.get(asset, year).starting_amount).to eq(usd(500_00))
        expect(described_class.get(income, year).starting_amount).to eq(usd(0))
      end
    end
  end
end
