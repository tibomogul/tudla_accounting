require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe TudlaAccounting::BalanceRebuilder, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization) }
  let!(:y2026) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let!(:y2027) { TudlaAccounting::PeriodCreator.call(organization, 2027) }

  before do
    TudlaAccounting.configuration.retained_earnings_account_code = "3900"
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash", category: "asset" },
      { code: "3000", name: "Equity", category: "equity", children: [
        { code: "3100", name: "Capital", category: "equity" },
        { code: "3900", name: "Retained Earnings", category: "equity" }
      ] },
      { code: "4000", name: "Income", category: "income", children: [
        { code: "4010", name: "Sales", category: "income" },
        { code: "4090", name: "Sales Returns", category: "income", contra_account: "4010" }
      ] },
      { code: "6000", name: "Rent", category: "expense" }
    ], organization)
    TudlaAccounting::StartingBalanceCreator.call(organization, Date.new(2026, 1, 1), [
      { account_id: account("1000").id, amount_cents: 400_00 },
      { account_id: account("3000").id, amount_cents: 400_00, children: [ { account_id: account("3100").id, amount_cents: 400_00 } ] }
    ], "USD")
    post("1000", "3100", 1_000, Time.zone.local(2026, 2, 1))
    post("1000", "4010", 500, Time.zone.local(2026, 6, 1))
    post("4090", "1000", 50, Time.zone.local(2026, 7, 1))
    post("6000", "1000", 120, Time.zone.local(2026, 8, 1))
    post("1000", "4010", 100, Time.zone.local(2027, 3, 1))
    draft("6000", "1000", 999, Time.zone.local(2026, 9, 1))
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def month(year, number) = year.children.order(:from_date)[number - 1]
  def stored = TudlaAccounting::Balance.where(organization: organization).order(:id).pluck(:account_id, :period_id, :starting_amount_cents, :current_amount_cents, :ending_amount_cents)
  def rebuilder = described_class.new(organization)

  def build_entry(debit, credit, amount, on)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: on)
    entry.details.build(account: account(debit), tally: :debit, amount_cents: amount * 100, currency: "USD", organization: organization)
    entry.details.build(account: account(credit), tally: :credit, amount_cents: amount * 100, currency: "USD", organization: organization)
    entry.save!
    entry
  end

  def post(...) = build_entry(...).tap { |entry| entry.post(entry.transacted_at) }
  def draft(...) = build_entry(...)

  it "finds nothing to fix in books kept by posting, with opening balances and a year end" do
    expect(rebuilder.differences).to be_empty
    expect(rebuilder.expected(account("3900"), y2027)).to eq(starting_amount_cents: 330_00, current_amount_cents: 0, ending_amount_cents: 330_00)
    expect(rebuilder.expected(account("1000"), month(y2027, 3))).to include(starting_amount_cents: 1_730_00, ending_amount_cents: 1_830_00)
  end

  it "reports corrupted balances, and puts back exactly what posting wrote" do
    original = stored
    TudlaAccounting::Balance.find_by(account: account("1000"), period: month(y2026, 6)).update_columns(current_amount_cents: 1, ending_amount_cents: 2)
    TudlaAccounting::Balance.find_by(account: account("1000"), period: y2027).update_columns(starting_amount_cents: 0)

    differences = rebuilder.differences
    expect(differences.map { |d| [ d.account.code, d.period.from_date.month, d.field ] }).to contain_exactly(
      [ "1000", 6, :current_amount_cents ], [ "1000", 6, :ending_amount_cents ], [ "1000", 1, :starting_amount_cents ]
    )
    expect(differences.find { |d| d.field == :current_amount_cents }).to have_attributes(stored: 1, expected: 500_00, missing?: false)

    expect(rebuilder.rebuild!).to eq(2)
    expect(stored).to eq(original)
    expect(rebuilder.differences).to be_empty
  end

  it "recreates a balance that was lost" do
    lost = TudlaAccounting::Balance.find_by(account: account("6000"), period: y2026)
    values = lost.attributes.slice("starting_amount_cents", "current_amount_cents", "ending_amount_cents")
    lost.delete

    difference = rebuilder.differences.sole
    expect(difference).to have_attributes(field: :missing, stored: nil, expected: 120_00, missing?: true)

    expect(rebuilder.rebuild!).to eq(1)
    expect(TudlaAccounting::Balance.find_by(account: account("6000"), period: y2026).attributes).to include(values.merge("currency" => "USD"))
  end

  it "keeps the opening balances, which only the stored first year holds" do
    TudlaAccounting::Balance.find_by(account: account("1000"), period: month(y2026, 1)).update_columns(starting_amount_cents: 0)
    rebuilder.rebuild!
    expect(TudlaAccounting::Balance.find_by(account: account("1000"), period: month(y2026, 1)).starting_amount_cents).to eq(400_00)
  end

  it "doesn't carry profit when no retained earnings account is configured" do
    TudlaAccounting.configuration.retained_earnings_account_code = nil
    expect(rebuilder.expected(account("3900"), y2027)[:starting_amount_cents]).to eq(0)
  end

  it "ignores lines whose posting time is outside every period, and other organizations" do
    other = create(:organization)
    TudlaAccounting::PeriodCreator.call(other, 2026)
    rent = TudlaAccounting::Detail.joins(:entry).where(account: account("6000")).where.not(tudla_accounting_entries: { posted_at: nil }).sole.entry
    TudlaAccounting::DatabaseProtection.allowing_posted_changes { rent.update_columns(posted_at: Time.zone.local(2030, 1, 1)) }
    expect(rebuilder.differences.select { |d| d.account.code == "6000" && d.field == :current_amount_cents }.map(&:expected)).to eq([ 0, 0 ]) # August and the year
    expect(described_class.new(other).differences).to be_empty
  end
end
