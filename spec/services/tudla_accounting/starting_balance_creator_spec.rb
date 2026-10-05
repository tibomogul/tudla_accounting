require "rails_helper"

RSpec.describe TudlaAccounting::StartingBalanceCreator, type: :service do
  let(:organization) { create(:organization) }
  let(:opening_date) { Date.new(2026, 1, 1) }

  def usd(cents) = Money.new(cents, "USD")
  def balance(account, period) = TudlaAccounting::Balance.find_by(account: account, period: period)

  let!(:assets) { create(:tudla_accounting_account, code: "1000", category: :asset, organization: organization) }
  let!(:cash) { create(:tudla_accounting_account, code: "1010", category: :asset, organization: organization, parent: assets) }
  let!(:equipment) { create(:tudla_accounting_account, code: "1500", category: :asset, organization: organization, parent: assets) }
  let!(:depreciation) do
    create(:tudla_accounting_account, code: "1505", category: :asset, organization: organization, parent: assets, contra_account: equipment)
  end

  let(:nodes) do
    [ { account_id: assets.id, amount_cents: 1_700_00, children: [
      { account_id: cash.id, amount_cents: 1_000_00 },
      { account_id: equipment.id, amount_cents: 1_000_00 },
      { account_id: depreciation.id, amount_cents: -300_00 } # contra: negative so children sum to the parent
    ] } ]
  end

  context "with a year of periods" do
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
    let(:months) { year.children.order(:from_date).to_a }

    it "sets the opening balance of every period containing the date, for every account" do
      expect { described_class.call(organization, opening_date, nodes, "USD") }.to change(TudlaAccounting::Balance, :count).by(8)

      [ year, months.first ].each do |period|
        expect(balance(assets, period)).to have_attributes(starting_amount: usd(1_700_00), current_amount: usd(0), ending_amount: usd(1_700_00),
                                                           currency: "USD", organization: organization)
        expect(balance(cash, period).starting_amount).to eq(usd(1_000_00))
      end
    end

    it "stores a contra account's balance on its own side, so later posting adds to it" do
      described_class.call(organization, opening_date, nodes, "USD")
      expect(balance(depreciation, year).starting_amount).to eq(usd(300_00))

      expense = create(:tudla_accounting_account, code: "6000", category: :expense, organization: organization)
      entry = build(:tudla_accounting_entry, organization: organization, transacted_at: Time.zone.local(2026, 2, 15))
      entry.details.build(account: expense, tally: :debit, amount_cents: 50_00, currency: "USD", organization: organization)
      entry.details.build(account: depreciation, tally: :credit, amount_cents: 50_00, currency: "USD", organization: organization)
      entry.save!
      entry.post(entry.transacted_at)

      expect(balance(depreciation, year).ending_amount).to eq(usd(350_00))
      expect(balance(assets, year).ending_amount).to eq(usd(1_650_00))
      expect(balance(equipment, year).ending_amount - balance(depreciation, year).ending_amount).to eq(usd(650_00))
    end

    it "lets later months start from the opening balance" do
      described_class.call(organization, opening_date, nodes, "USD")
      expect(TudlaAccounting::Balance.get(cash, months[3]).starting_amount).to eq(usd(1_000_00))
    end

    it "accepts string keys" do
      described_class.call(organization, opening_date, [ { "account_id" => cash.id, "amount_cents" => 500_00 } ], "USD")
      expect(balance(cash, year).starting_amount).to eq(usd(500_00))
    end

    it "checks that parents match their children at every level" do
      nested = [ { account_id: assets.id, amount_cents: 100_00, children: [
        { account_id: cash.id, amount_cents: 100_00, children: [ { account_id: equipment.id, amount_cents: 60_00 } ] }
      ] } ]

      expect { described_class.call(organization, opening_date, nested, "USD") }
        .to raise_error(ArgumentError, "Amounts mismatch for account 1010. Parent amount: 10000, Sum of children: 6000")
      expect(TudlaAccounting::Balance.count).to eq(0)
    end

    it "refuses to replace existing opening balances unless overwriting" do
      described_class.call(organization, opening_date, nodes, "USD")
      expect { described_class.call(organization, opening_date, nodes, "USD") }.to raise_error(ArgumentError, /already exists/)
    end

    it "replaces opening balances when overwriting, keeping activity and later balances consistent" do
      described_class.call(organization, opening_date, [ { account_id: cash.id, amount_cents: 1_000_00 } ], "USD")
      april = TudlaAccounting::Balance.get(cash, months[3])
      TudlaAccounting::Balance.get(cash, year).update_current_amount(usd(200_00), "debit") # activity during the year

      described_class.call(organization, opening_date, [ { account_id: cash.id, amount_cents: 1_500_00 } ], "USD", true)

      expect(balance(cash, year)).to have_attributes(starting_amount: usd(1_500_00), current_amount: usd(200_00), ending_amount: usd(1_700_00))
      expect(april.reload).to have_attributes(starting_amount: usd(1_500_00), ending_amount: usd(1_500_00))
    end

    it "requires overwriting once activity has been posted, then moves the later balances" do
      TudlaAccounting::Balance.get(cash, months[2]).post(usd(100_00), "debit") # March activity, before opening balances

      expect { described_class.call(organization, opening_date, [ { account_id: cash.id, amount_cents: 400_00 } ], "USD") }
        .to raise_error(ArgumentError, /already exists/)

      described_class.call(organization, opening_date, [ { account_id: cash.id, amount_cents: 400_00 } ], "USD", true)

      expect(balance(cash, months[2])).to have_attributes(starting_amount: usd(400_00), current_amount: usd(100_00), ending_amount: usd(500_00))
      expect(balance(cash, year)).to have_attributes(starting_amount: usd(400_00), current_amount: usd(100_00), ending_amount: usd(500_00))
    end

    it "refuses a date that is not in the first period at every level" do
      expect { described_class.call(organization, Date.new(2026, 2, 1), nodes, "USD") }.to raise_error(ArgumentError, /has earlier periods/)
    end

    it "is not blocked by another organization's earlier periods" do
      TudlaAccounting::PeriodCreator.call(create(:organization), 2025)
      expect { described_class.call(organization, opening_date, nodes, "USD") }.not_to raise_error
    end

    it "only uses the organization's own accounts" do
      stranger = create(:tudla_accounting_account, code: "9999", organization: create(:organization))
      expect { described_class.call(organization, opening_date, [ { account_id: stranger.id, amount_cents: 1 } ], "USD") }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  it "refuses a date with no periods" do
    expect { described_class.call(organization, opening_date, nodes, "USD") }.to raise_error(ArgumentError, "No periods found for the specified date")
  end
end
