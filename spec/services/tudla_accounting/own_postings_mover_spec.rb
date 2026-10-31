require "rails_helper"

# Books posted before only accounts without sub-accounts took postings can have parents
# holding amounts of their own. BalanceRebuilder#own_amounts finds them, and
# OwnPostingsMover moves the lines down.
RSpec.describe TudlaAccounting::OwnPostingsMover, type: :service do
  let(:organization) { create(:organization, currency: "USD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:cash) { create(:tudla_accounting_account, code: "1000", name: "Cash", category: :asset, organization: organization) }
  let(:capital) { create(:tudla_accounting_account, code: "3100", name: "Capital", category: :equity, organization: organization) }
  let(:expenses) { create(:tudla_accounting_account, code: "6000", name: "Expenses", category: :expense, organization: organization) }

  def post(account, cents, on)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: "Fees", transacted_at: on)
    entry.details.build(account: account, tally: :debit, amount_cents: cents, currency: "USD", organization: organization)
    entry.details.build(account: capital, tally: :credit, amount_cents: cents, currency: "USD", organization: organization)
    entry.tap(&:save!).tap { entry.post(on) }
  end

  # As older books could: the triggers and validations refuse it now.
  def legacy_sub_account(code, parent, **attributes)
    account = build(:tudla_accounting_account, code: code, category: parent.category, organization: organization, parent: parent, **attributes)
    TudlaAccounting::DatabaseProtection.allowing_posted_changes { account.save!(validate: false) }
    account
  end

  def rebuilder = TudlaAccounting::BalanceRebuilder.new(organization)
  def balance(account, period = year) = TudlaAccounting::Balance.find_by!(account: account, period: period).ending_amount_cents

  it "lists accounts with sub-accounts holding posted lines or an opening balance of their own" do
    TudlaAccounting::StartingBalanceCreator.call(organization, year.from_date.to_date, [ { account_id: cash.id, amount_cents: 500_00 }, { account_id: capital.id, amount_cents: 500_00 } ], "USD")
    post(expenses, 12_50, Time.zone.local(2026, 2, 1))
    post(expenses, 7_50, Time.zone.local(2026, 3, 1))
    fees = legacy_sub_account("6010", expenses)
    post(fees, 1_00, Time.zone.local(2026, 3, 2))
    legacy_sub_account("1010", cash)
    tidy = create(:tudla_accounting_account, code: "4000", category: :income, organization: organization)
    create(:tudla_accounting_account, code: "4010", category: :income, organization: organization, parent: tidy)

    expect(rebuilder.own_amounts.map(&:to_h)).to eq([ { account: cash, lines: 0, opening_cents: 500_00 }, { account: expenses, lines: 2, opening_cents: 0 } ])
    expect(rebuilder.differences).to be_empty
  end

  it "moves the lines to a sub-account, keeping the parent's balances and rebuilding the sub-account's" do
    first = post(expenses, 12_50, Time.zone.local(2026, 2, 1))
    post(expenses, 7_50, Time.zone.local(2026, 3, 1))
    fees = legacy_sub_account("6010", expenses)
    legacy_sub_account("6020", expenses)

    expect(described_class.call(expenses, to: fees)).to eq(2)
    expect(first.details.find_by!(tally: :debit).account).to eq(fees)
    expect([ balance(expenses), balance(fees) ]).to eq([ 20_00, 20_00 ])
    expect(rebuilder.own_amounts).to be_empty
    expect(rebuilder.differences).to be_empty
    expect(TudlaAccounting::AuditEvent.find_by!(action: "account.postings_moved")).to have_attributes(subject: expenses, details: { "to" => "6010", "lines" => 2, "entries" => 2 })
    expect(TudlaAccounting::AuditEvent.where(action: "balances.rebuilt").count).to eq(1)
  end

  it "refuses what isn't a move of the account's own lines to an account without sub-accounts beneath it" do
    post(expenses, 12_50, Time.zone.local(2026, 2, 1))
    fees = legacy_sub_account("6010", expenses)
    legacy_sub_account("6011", fees)
    euros = legacy_sub_account("6020", expenses, currency: "EUR")
    travel = create(:tudla_accounting_account, code: "6500", name: "Travel", category: :expense, organization: organization)
    taxis = create(:tudla_accounting_account, code: "6510", category: :expense, organization: organization, parent: travel)

    expect { described_class.call(expenses, to: taxis) }.to raise_error(ArgumentError, "#{taxis.code_with_name} isn't a sub-account of 6000 - Expenses")
    expect { described_class.call(expenses, to: fees) }.to raise_error(ArgumentError, /\A#{fees.code_with_name} has sub-accounts \(6011\)/)
    expect { described_class.call(travel, to: taxis) }.to raise_error(ArgumentError, "6500 - Travel has no postings of its own")
    expect { described_class.call(expenses, to: euros) }.to raise_error(ArgumentError, "#{euros.code_with_name} is held in EUR, but the lines are in USD")

    year.children.order(:from_date).first(2).each(&:close!)
    plain = legacy_sub_account("6030", expenses)
    expect { described_class.call(expenses, to: plain) }.to raise_error(ArgumentError, "#{year.children.order(:from_date).second.label} is closed; reopen it to move its lines")
    expect(TudlaAccounting::AuditEvent.where(action: "account.postings_moved")).to be_empty
  end
end
