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

  describe "#signed_amount" do
    let(:organization) { create(:organization) }

    def signed(category, tally, contra: false)
      account = create(:tudla_accounting_account, category: category, organization: organization)
      account.update!(contra_account: create(:tudla_accounting_account, organization: organization)) if contra
      build(:tudla_accounting_detail, account: account, tally: tally, amount_cents: 100_00, organization: organization).signed_amount.cents
    end

    it "is positive when the tally matches the account's normal side" do
      expect(signed(:asset, :debit)).to eq(100_00)
      expect(signed(:expense, :debit)).to eq(100_00)
      expect(signed(:liability, :credit)).to eq(100_00)
      expect(signed(:equity, :credit)).to eq(100_00)
      expect(signed(:income, :credit)).to eq(100_00)
    end

    it "is negative when the tally is against the account's normal side" do
      expect(signed(:asset, :credit)).to eq(-100_00)
      expect(signed(:liability, :debit)).to eq(-100_00)
      expect(signed(:income, :debit)).to eq(-100_00)
    end

    it "flips for contra accounts" do
      expect(signed(:equity, :debit, contra: true)).to eq(100_00)
      expect(signed(:asset, :credit, contra: true)).to eq(100_00)
    end
  end

  describe "#post" do
    let(:organization) { create(:organization) }
    let(:entry) { create(:tudla_accounting_entry, organization: organization) }
    let(:root_account) { create(:tudla_accounting_account, category: :asset, organization: organization) }
    let(:parent_account) { create(:tudla_accounting_account, category: :asset, organization: organization, parent: root_account) }
    let(:child_account) { create(:tudla_accounting_account, category: :asset, organization: organization, parent: parent_account) }
    let(:year) { create(:tudla_accounting_period, organization: organization, from_date: Date.new(2026, 1, 1), thru_date: Date.new(2026, 12, 31)) }
    let(:q2) { create(:tudla_accounting_period, organization: organization, parent: year, from_date: Date.new(2026, 4, 1), thru_date: Date.new(2026, 6, 30)) }
    let!(:apr) { create(:tudla_accounting_period, organization: organization, parent: q2, from_date: Date.new(2026, 4, 1), thru_date: Date.new(2026, 4, 30)) }
    let!(:may) { create(:tudla_accounting_period, organization: organization, parent: q2, from_date: Date.new(2026, 5, 1), thru_date: Date.new(2026, 5, 31)) }

    def usd(cents) = Money.new(cents, "USD")
    def balance_for(account, period) = TudlaAccounting::Balance.find_by(account: account, period: period)

    def post_detail(account, cents, tally, at)
      create(:tudla_accounting_detail, entry: entry, organization: organization, account: account,
                                       amount_cents: cents, tally: tally).tap { |d| d.post(at) }
    end

    it "posts to the leaf period containing the date and links the detail to that balance" do
      detail = post_detail(child_account, 100_00, :debit, Time.zone.local(2026, 4, 15))

      expect(detail.reload.balance).to eq(balance_for(child_account, apr))
      expect(detail.balance.current_amount).to eq(usd(100_00))
    end

    it "posts on the last day of a period" do
      detail = post_detail(child_account, 100_00, :debit, Time.zone.local(2026, 4, 30, 18))
      expect(detail.reload.balance.period).to eq(apr)
    end

    it "reuses an existing balance" do
      post_detail(child_account, 100_00, :debit, Time.zone.local(2026, 4, 15))
      expect { post_detail(child_account, 40_00, :credit, Time.zone.local(2026, 4, 20)) }
        .not_to change(TudlaAccounting::Balance, :count)
      expect(balance_for(child_account, apr).current_amount).to eq(usd(60_00))
    end

    it "rolls up through ancestor accounts and ancestor periods" do
      post_detail(child_account, 100_00, :debit, Time.zone.local(2026, 4, 15))
      post_detail(child_account, 200_00, :debit, Time.zone.local(2026, 5, 15))

      [ child_account, parent_account, root_account ].each do |account|
        expect(balance_for(account, apr)).to have_attributes(starting_amount: usd(0), current_amount: usd(100_00), ending_amount: usd(100_00))
        expect(balance_for(account, may)).to have_attributes(starting_amount: usd(100_00), current_amount: usd(200_00), ending_amount: usd(300_00))
        expect(balance_for(account, q2).current_amount).to eq(usd(300_00))
        expect(balance_for(account, year).current_amount).to eq(usd(300_00))
      end
    end

    it "updates later periods when back-dating into an earlier period" do
      may_detail = post_detail(child_account, 200_00, :debit, Time.zone.local(2026, 5, 15))
      apr_detail = post_detail(child_account, 100_00, :debit, Time.zone.local(2026, 4, 15))

      [ child_account, parent_account, root_account ].each do |account|
        expect(balance_for(account, apr)).to have_attributes(starting_amount: usd(0), current_amount: usd(100_00), ending_amount: usd(100_00))
        expect(balance_for(account, may)).to have_attributes(starting_amount: usd(100_00), current_amount: usd(200_00), ending_amount: usd(300_00))
        expect(balance_for(account, q2).current_amount).to eq(usd(300_00))
        expect(balance_for(account, year).current_amount).to eq(usd(300_00))
      end
      expect(apr_detail.reload.balance.period).to eq(apr)
      expect(may_detail.reload.balance.period).to eq(may)
    end

    it "only posts to periods belonging to the detail's organization" do
      other_org = create(:organization)
      create(:tudla_accounting_period, organization: other_org, from_date: Date.new(2026, 4, 1), thru_date: Date.new(2026, 4, 30))

      detail = post_detail(child_account, 100_00, :debit, Time.zone.local(2026, 4, 15))
      expect(detail.reload.balance.period).to eq(apr)
    end

    it "raises when no period covers the date" do
      detail = create(:tudla_accounting_detail, entry: entry, organization: organization, account: child_account)
      expect { detail.post(Time.zone.local(2027, 1, 15)) }.to raise_error(ArgumentError, "no valid period found for the posted date")
    end

    it "raises when more than one leaf period covers the date" do
      create(:tudla_accounting_period, organization: organization, from_date: Date.new(2026, 4, 10), thru_date: Date.new(2026, 4, 20))
      detail = create(:tudla_accounting_detail, entry: entry, organization: organization, account: child_account)
      expect { detail.post(Time.zone.local(2026, 4, 15)) }.to raise_error(ArgumentError, "multiple periods found for the posted date")
    end

    it "raises when posted_at is not a time" do
      detail = create(:tudla_accounting_detail, entry: entry, organization: organization, account: child_account)
      expect { detail.post("2026-04-15") }.to raise_error(ArgumentError, "posted_at must be a datetime")
      expect { detail.post(Date.new(2026, 4, 15)) }.to raise_error(ArgumentError, "posted_at must be a datetime")
    end
  end
end
