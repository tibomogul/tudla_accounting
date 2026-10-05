require "rails_helper"
require_relative "../../support/configuration"

# Each root period is a financial year. Balances carry across years automatically:
# asset, liability and equity accounts continue, income and expense accounts restart
# at zero, and the year's net profit moves into the retained earnings account.
RSpec.describe "Year-end carry-forward" do
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
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def usd(amount) = Money.from_amount(amount, "USD")
  def opening(code, year) = TudlaAccounting::Balance.get(account(code), year).starting_amount
  def closing(code, year) = TudlaAccounting::Balance.get(account(code), year).ending_amount

  def post(debit, credit, amount, on)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: on)
    entry.details.build(account: account(debit), tally: :debit, amount_cents: usd(amount).cents, currency: "USD", organization: organization)
    entry.details.build(account: account(credit), tally: :credit, amount_cents: usd(amount).cents, currency: "USD", organization: organization)
    entry.save!
    entry.post(on)
  end

  def record_2026
    post("1000", "3100", 1_000, Time.zone.local(2026, 2, 1)) # capital
    post("1000", "4010", 500, Time.zone.local(2026, 6, 1))   # sale
    post("4090", "1000", 50, Time.zone.local(2026, 7, 1))    # refund (contra income)
    post("6000", "1000", 120, Time.zone.local(2026, 8, 1))   # rent
  end

  def expect_2027_books
    expect(opening("1000", y2027)).to eq(usd(1_330))
    expect(opening("3100", y2027)).to eq(usd(1_000))
    expect(opening("3900", y2027)).to eq(usd(330)) # 500 sales - 50 returns - 120 rent
    expect(opening("3000", y2027)).to eq(usd(1_330))
    %w[4000 4010 4090 6000].each { |code| expect(opening(code, y2027)).to eq(usd(0)) }
  end

  it "opens the next year with balance-sheet balances, zero income and expenses, and the profit in retained earnings" do
    record_2026
    expect_2027_books
  end

  it "gives the same books when the later year is posted first and earlier entries are back-dated" do
    post("1000", "4010", 100, Time.zone.local(2027, 1, 15))
    %w[1000 3000 3100 3900 4000 4010 4090 6000].each { |code| TudlaAccounting::Balance.get(account(code), y2027) } # all exist already
    record_2026

    expect_2027_books
    expect(closing("1000", y2027)).to eq(usd(1_430))
    expect(closing("4010", y2027)).to eq(usd(100))
  end

  it "keeps the books balanced in the later year" do
    record_2026
    post("1000", "4010", 100, Time.zone.local(2027, 3, 1))

    assets = closing("1000", y2027)
    expect(assets).to eq(closing("3000", y2027) + closing("4000", y2027) - closing("6000", y2027))
  end

  it "carries through years with no activity" do
    y2028 = TudlaAccounting::PeriodCreator.call(organization, 2028)
    record_2026

    expect(opening("1000", y2028)).to eq(usd(1_330))
    expect(opening("3900", y2028)).to eq(usd(330))
    expect(opening("4010", y2028)).to eq(usd(0))
  end

  it "accumulates profit across several years" do
    y2028 = TudlaAccounting::PeriodCreator.call(organization, 2028)
    record_2026
    post("1000", "4010", 200, Time.zone.local(2027, 5, 1))

    expect(opening("3900", y2028)).to eq(usd(530))
    expect(opening("1000", y2028)).to eq(usd(1_530))
  end

  it "carries opening balances loaded into the first year" do
    TudlaAccounting::StartingBalanceCreator.call(organization, Date.new(2026, 1, 1),
                                                 [ { account_id: account("1000").id, amount_cents: 250_00 } ], "USD")
    expect(opening("1000", y2027)).to eq(usd(250))
  end

  it "moves later years when first-year opening balances are overwritten" do
    TudlaAccounting::Balance.get(account("1000"), y2027)
    TudlaAccounting::Balance.get(account("4010"), y2027)
    TudlaAccounting::StartingBalanceCreator.call(organization, Date.new(2026, 1, 1),
                                                 [ { account_id: account("1000").id, amount_cents: 250_00 },
                                                   { account_id: account("4010").id, amount_cents: 0 } ], "USD", true)

    expect(opening("1000", y2027)).to eq(usd(250))
    expect(opening("4010", y2027)).to eq(usd(0))
  end

  it "ignores other organizations' years" do
    other = create(:organization)
    TudlaAccounting::PeriodCreator.call(other, 2025)
    record_2026

    expect(opening("1000", y2026)).to eq(usd(0))
  end

  context "without a retained earnings account configured" do
    before { TudlaAccounting.configuration.retained_earnings_account_code = nil }

    it "still restarts income and expenses each year, but cannot carry the profit" do
      record_2026
      expect(opening("4010", y2027)).to eq(usd(0))
      expect(opening("1000", y2027)).to eq(usd(1_330))
      expect(opening("3900", y2027)).to eq(usd(0))
    end
  end

  it "reports a year's net profit" do
    record_2026
    expect(TudlaAccounting::Balance.net_profit(organization, y2026)).to eq(usd(330))
  end
end
