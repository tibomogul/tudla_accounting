require "rails_helper"

# Moving retained earnings, and what the rebuild does, is in year_end_spec.
RSpec.describe TudlaAccounting::AccountRoleAssigner do
  let(:organization) { create(:organization) }
  let(:receivables) { create(:tudla_accounting_account, code: "1100", category: :asset, organization: organization, role: :receivable) }
  let(:other) { create(:tudla_accounting_account, code: "1150", category: :asset, organization: organization) }

  def post_to(account)
    capital = TudlaAccounting::Account.find_by(organization: organization, code: "3100") ||
              create(:tudla_accounting_account, code: "3100", category: :equity, organization: organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026) unless TudlaAccounting::Period.where(organization: organization).exists?
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: Time.zone.local(2026, 2, 1))
    entry.details.build(account: account, tally: :debit, amount_cents: 100, currency: "USD", organization: organization)
    entry.details.build(account: capital, tally: :credit, amount_cents: 100, currency: "USD", organization: organization)
    entry.save!
    entry.post(entry.transacted_at)
  end

  it "moves a role from the account holding it" do
    receivables

    expect(described_class.save(other, :receivable)).to be(true)
    expect([ other, receivables ].map { |account| account.reload.role }).to eq([ "receivable", nil ])
  end

  it "saves a new account, and its other changes, with the role" do
    receivables
    account = TudlaAccounting::Account.new(organization: organization, code: "1160", name: "Trade debtors", category: :asset)

    expect(described_class.save(account, "receivable")).to be(true)
    expect(account).to be_persisted
    expect(receivables.reload.role).to be_nil
  end

  it "refuses another organization's account, leaving its own roles alone" do
    receivables
    stranger = create(:tudla_accounting_account, code: "1150", category: :asset, organization: create(:organization))

    expect {
      described_class.batch(organization) { |assigner| assigner.save(stranger, :receivable) }
    }.to raise_error(ArgumentError, /1150 isn't one of/)
    expect([ receivables, stranger ].map { |account| account.reload.role }).to eq([ "receivable", nil ])
  end

  it "leaves receivables and payables on an account with postings" do
    post_to(receivables.children.sole)

    expect(described_class.save(other, :receivable)).to be(false)
    expect(other.errors[:role]).to eq([ "Receivables is held by 1100 - #{receivables.name}, which keeps it now that it, or an account beneath it, has posted lines" ])
    expect([ other, receivables ].map { |account| account.reload.role }).to eq([ nil, "receivable" ])
  end

  it "moves receivables from an account with only opening balances" do
    year = TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::StartingBalanceCreator.call(organization, year.from_date.to_date, [ { account_id: receivables.id, amount_cents: 300 } ], "USD")

    expect(described_class.save(other, :receivable)).to be(true)
    expect([ other, receivables ].map { |account| account.reload.role }).to eq([ "receivable", nil ])
  end

  it "keeps receivables on an account once it has posted lines" do
    post_to(receivables.children.sole)

    expect(described_class.save(receivables, nil)).to be(false)
    expect(receivables.errors[:role]).to eq([ "stays Receivables now that it, or an account beneath it, has posted lines" ])
    expect(receivables.reload.role).to eq("receivable")
  end

  # Its earlier lines opened nothing owed, so it would show more owed than its open items.
  it "refuses receivables for an account with posted lines, on it or beneath it" do
    message = "Receivables can't be given to an account with posted lines, which opened nothing owed; mark it before posting, or use a new account"
    post_to(other)

    expect(described_class.save(other, :receivable)).to be(false)
    expect(other.errors[:role]).to eq([ message ])

    parent = create(:tudla_accounting_account, code: "1200", category: :asset, organization: organization)
    post_to(create(:tudla_accounting_account, code: "1201", category: :asset, organization: organization, parent: parent))
    expect(described_class.save(parent.reload, :receivable)).to be(false)
    expect(parent.reload.role).to be_nil
  end

  it "gives receivables and payables to accounts with only drafts or opening balances" do
    year = TudlaAccounting::PeriodCreator.call(organization, 2026)
    capital = create(:tudla_accounting_account, code: "3100", category: :equity, organization: organization)
    build(:tudla_accounting_entry, organization: organization, transacted_at: Time.zone.local(2026, 2, 1)).tap do |entry|
      entry.details.build(account: other, tally: :debit, amount_cents: 100, currency: "USD", organization: organization)
      entry.details.build(account: capital, tally: :credit, amount_cents: 100, currency: "USD", organization: organization)
    end.save!
    expect(described_class.save(other, :receivable)).to be(true)

    opened = create(:tudla_accounting_account, code: "2100", category: :liability, organization: organization)
    TudlaAccounting::StartingBalanceCreator.call(organization, year.from_date.to_date, [ { account_id: opened.id, amount_cents: 300 } ], "USD")
    expect(described_class.save(opened.reload, :payable)).to be(true)
  end

  describe "the sub-account in the organization's currency" do
    it "is made with the receivable or payable role, taking the account's own opening balance, so it adds up to what is beneath it" do
      year = TudlaAccounting::PeriodCreator.call(organization, 2026)
      debtors = create(:tudla_accounting_account, code: "1200", name: "Debtors", category: :asset, organization: organization)
      staff = create(:tudla_accounting_account, code: "1201", category: :asset, currency: nil, organization: organization, parent: debtors)
      TudlaAccounting::StartingBalanceCreator.call(organization, year.from_date.to_date,
                                                   [ { account_id: debtors.id, amount_cents: 100, children: [ { account_id: staff.id, amount_cents: 100 } ] } ], "USD")
      # Opening balances keep a parent equal to its children, so the account's own (from
      # before that rule, or loaded with the role) goes straight into its balances.
      TudlaAccounting::Balance.where(account: debtors).update_all("starting_amount_cents = starting_amount_cents + 400, ending_amount_cents = ending_amount_cents + 400")

      expect(described_class.save(debtors, :receivable)).to be(true)
      home = debtors.children.find_by!(code: "1200-USD")
      expect(home).to have_attributes(name: "Debtors - USD", currency: "USD", category: "asset", role: nil)
      expect(year.subtree.map { |period| TudlaAccounting::Balance.peek(home, period).ending_amount_cents }.uniq).to eq([ 400 ])
      expect(TudlaAccounting::BalanceRebuilder.new(organization).differences).to be_empty

      expect { described_class.save(debtors, nil) && described_class.save(debtors, :receivable) }.not_to(change { debtors.children.count })
      payables = create(:tudla_accounting_account, code: "2100", category: :liability, organization: organization)
      expect(described_class.save(payables, :payable)).to be(true)
      expect(payables.children.pluck(:code)).to eq([ "2100-USD" ])
      expect(described_class.save(create(:tudla_accounting_account, code: "3900", category: :equity, organization: organization), :retained_earnings)).to be(true)
      expect(TudlaAccounting::Account.where(organization: organization, code: "3900-USD")).not_to exist
    end

    it "refuses the role when the sub-account's code is taken" do
      create(:tudla_accounting_account, code: "1150-USD", category: :asset, organization: organization)

      expect(described_class.save(other, :receivable)).to be(false)
      expect(other.errors[:role]).to eq([ "needs a sub-account in USD for receivables in USD, made as 1150-USD, but 1150-USD is already taken; " \
                                          "move that account beneath 1150, or give it another code" ])
      expect(other.reload.role).to be_nil
    end
  end

  # The earlier years' profit carried into the closed periods would move.
  describe "retained earnings and closed periods" do
    let(:retained) { create(:tudla_accounting_account, code: "3900", category: :equity, organization: organization) }
    let(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
    let(:next_year) { TudlaAccounting::PeriodCreator.call(organization, 2027) }
    let(:message) do
      "can't change from or to Retained earnings while periods after 2026 are closed, as the profit carried into them " \
        "would be restated; reopen them first (the latest closed is Jan 2027)"
    end

    def january(year) = year.children.order(:from_date).first

    before { year && next_year }

    it "changes while only the first year's periods are closed, whose balances it doesn't move" do
      year.close!
      expect(described_class.save(retained, :retained_earnings)).to be(true)
    end

    it "doesn't change while a later year's period is closed, until it's reopened" do
      year.close!
      january(next_year).close!

      expect(described_class.save(retained, :retained_earnings)).to be(false)
      expect(retained.errors[:role]).to eq([ message ])

      january(next_year).reopen!(reason: "Restate retained earnings")
      expect(described_class.save(retained, :retained_earnings)).to be(true)
    end

    it "doesn't move or come off while a later year's period is closed" do
      described_class.save!(retained, :retained_earnings)
      accumulated = create(:tudla_accounting_account, code: "3950", category: :equity, organization: organization)
      year.close!
      january(next_year).close!

      expect(described_class.save(accumulated, :retained_earnings)).to be(false)
      expect(accumulated.errors[:role]).to eq([ message ])
      expect(described_class.save(retained, nil)).to be(false)
      expect([ accumulated, retained ].map { |account| account.reload.role }).to eq([ nil, "retained_earnings" ])
    end
  end

  it "rolls back the whole batch when one of its saves is refused" do
    receivables
    other
    payables = create(:tudla_accounting_account, code: "2100", category: :liability, organization: organization)
    equipment = create(:tudla_accounting_account, code: "1500", category: :asset, organization: organization)

    result = described_class.batch(organization) do |assigner|
      assigner.save(other, :receivable)
      assigner.save(payables, :payable)
      assigner.save(equipment, :retained_earnings) # not an equity account
    end

    expect(result).to be(false)
    expect(equipment.errors[:role]).to be_present
    expect([ receivables, other, payables, equipment ].map { |account| account.reload.role }).to eq([ "receivable", nil, nil, nil ])
  end

  it "rolls back only its own batch inside a caller's transaction" do
    receivables
    ActiveRecord::Base.transaction do
      other.update!(name: "Trade debtors")
      result = described_class.batch(organization) do |assigner|
        assigner.save(other, :receivable)
        assigner.save(receivables, :retained_earnings) # not an equity account
      end
      expect(result).to be(false)
    end

    expect(other.reload).to have_attributes(name: "Trade debtors", role: nil)
    expect(receivables.reload.role).to eq("receivable")
  end

  it "raises with save! when the role can't change" do
    post_to(receivables.children.sole)
    expect { described_class.save!(other, :receivable) }.to raise_error(ActiveRecord::RecordInvalid, /held by 1100/)
  end

  describe "rebuilding after a change to retained earnings" do
    let(:retained) { create(:tudla_accounting_account, code: "3900", category: :equity, organization: organization) }

    def rebuilds = TudlaAccounting::AuditEvent.where(organization: organization, action: "balances.rebuilt")

    it "rebuilds the balances as it saves" do
      post_to(other)

      expect { expect(described_class.save(retained, :retained_earnings)).to be(true) }.to change { rebuilds.count }.by(1)
      expect(TudlaAccounting::BalanceRebuilder.new(organization).differences).to be_empty
    end

    it "rebuilds once when the role moves between accounts" do
      described_class.save!(retained, :retained_earnings)
      post_to(other)
      accumulated = create(:tudla_accounting_account, code: "3950", category: :equity, organization: organization)

      expect { described_class.save!(accumulated, :retained_earnings) }.to change { rebuilds.count }.by(1)
    end

    it "rebuilds once for a batch of changes" do
      post_to(other)
      accumulated = create(:tudla_accounting_account, code: "3950", category: :equity, organization: organization)

      expect do
        described_class.batch(organization) do |assigner|
          assigner.save!(retained, :retained_earnings)
          assigner.save!(accumulated, :retained_earnings)
        end
      end.to change { rebuilds.count }.by(1)
      expect(TudlaAccounting::BalanceRebuilder.new(organization).differences).to be_empty
    end

    it "doesn't rebuild a batch it rolls back" do
      post_to(other)
      retained

      expect do
        result = described_class.batch(organization) do |assigner|
          assigner.save(retained, :retained_earnings)
          assigner.save(other, :payable) # not a liability account
        end
        expect(result).to be(false)
      end.not_to change { rebuilds.count }
      expect(retained.reload.role).to be_nil
    end

    it "doesn't rebuild when the change is refused" do
      post_to(other)
      retained.name = ""

      expect { expect(described_class.save(retained, :retained_earnings)).to be(false) }.not_to change { rebuilds.count }
    end

    it "needs no rebuild on books without balances, nor for other roles" do
      expect { described_class.save(retained, :retained_earnings) }.not_to change { rebuilds.count }
      receivables
      post_to(other)
      trade = create(:tudla_accounting_account, code: "1160", category: :asset, organization: organization)
      expect { expect(described_class.save(trade, :receivable)).to be(true) }.not_to change { rebuilds.count }
    end
  end

  it "leaves the role with its holder when the holder can't be saved" do
    receivables.update_column(:name, "") # invalid, as only code skipping validations can make it

    expect(described_class.save(other, :receivable)).to be(false)
    expect(other.errors[:role]).to eq([ "can't move from 1100 - : Name can't be blank" ])
    expect([ other, receivables ].map { |account| account.reload.role }).to eq([ nil, "receivable" ])
  end

  it "gives the role back to its holder when the account can't be saved" do
    receivables
    other.name = ""

    expect(described_class.save(other, :receivable)).to be(false)
    expect(other.errors[:name]).to be_present
    expect(receivables.reload.role).to eq("receivable")
  end
end
