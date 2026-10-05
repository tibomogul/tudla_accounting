require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe "Reports", type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, currency: "AUD") }
  let!(:y2026) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let!(:y2027) { TudlaAccounting::PeriodCreator.call(organization, 2027) }

  def month(year, number) = year.children.order(:from_date).to_a[number - 1]
  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")

  def post(debit, credit, amount, on)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: on)
    entry.details.build(account: account(debit), tally: :debit, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
    entry.details.build(account: account(credit), tally: :credit, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
    entry.save!
    entry.post(on)
  end

  before do
    TudlaAccounting.configuration.retained_earnings_account_code = "3900"
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Assets", category: "asset", children: [
        { code: "1010", name: "Cash", category: "asset" },
        { code: "1500", name: "Equipment", category: "asset" },
        { code: "1505", name: "Accumulated Depreciation", category: "asset", contra_account: "1500" }
      ] },
      { code: "2000", name: "Loan", category: "liability" },
      { code: "3000", name: "Equity", category: "equity", children: [
        { code: "3100", name: "Capital", category: "equity" },
        { code: "3900", name: "Retained Earnings", category: "equity" }
      ] },
      { code: "4000", name: "Sales", category: "income" },
      { code: "4090", name: "Sales Returns", category: "income", contra_account: "4000" },
      { code: "6000", name: "Expenses", category: "expense", children: [
        { code: "6100", name: "Rent", category: "expense" },
        { code: "6200", name: "Depreciation", category: "expense" },
        { code: "6900", name: "Unused", category: "expense" }
      ] }
    ], organization)

    TudlaAccounting::StartingBalanceCreator.call(organization, Date.new(2026, 1, 1), [
      { account_id: account("1000").id, amount_cents: 10_000_00, children: [
        { account_id: account("1010").id, amount_cents: 7_000_00 }, { account_id: account("1500").id, amount_cents: 4_000_00 },
        { account_id: account("1505").id, amount_cents: -1_000_00 }
      ] },
      { account_id: account("2000").id, amount_cents: 2_000_00 },
      { account_id: account("3000").id, amount_cents: 8_000_00, children: [ { account_id: account("3100").id, amount_cents: 8_000_00 } ] }
    ], "AUD")

    post("1010", "4000", 1_500, Time.zone.local(2026, 3, 5))  # sales
    post("4090", "1010", 100, Time.zone.local(2026, 3, 20))   # a refund
    post("6100", "1010", 400, Time.zone.local(2026, 4, 1))    # rent
    post("6200", "1505", 250, Time.zone.local(2026, 4, 30))   # depreciation
    post("1010", "4000", 600, Time.zone.local(2027, 2, 1))    # next year
  end

  def rows(report, category) = report.rows(category).map { |row| [ row.account.code, row.depth, row.amount ] }

  describe TudlaAccounting::Reports::BalanceSheet do
    it "shows balances at the month end by category, contra accounts as deductions, skipping empty accounts" do
      report = described_class.new(organization, month(y2026, 4))

      expect(rows(report, "asset")).to eq([
        [ "1000", 0, aud(10_750) ], [ "1010", 1, aud(8_000) ], [ "1500", 1, aud(4_000) ], [ "1505", 1, aud(-1_250) ]
      ])
      expect(rows(report, "equity")).to eq([ [ "3000", 0, aud(8_000) ], [ "3100", 1, aud(8_000) ] ])
      expect(report.total("liability")).to eq(aud(2_000))
      expect(report.current_year_earnings).to eq(aud(750)) # 1,500 - 100 - 400 - 250
      expect(report.total_equity).to eq(aud(8_750))
      expect(report.liabilities_and_equity).to eq(aud(10_750))
      expect(report).to be_balanced
    end

    it "is as at the end of the chosen month" do
      expect(described_class.new(organization, month(y2026, 3)).current_year_earnings).to eq(aud(1_400))
    end

    it "balances in a later year, with last year's profit in retained earnings" do
      report = described_class.new(organization, month(y2027, 2))

      expect(rows(report, "equity")).to include([ "3900", 1, aud(750) ])
      expect(report.current_year_earnings).to eq(aud(600))
      expect(report).to be_balanced
    end

    it "shows a difference when the books don't balance" do
      TudlaAccounting::Balance.get(account("2000"), month(y2026, 4)).update!(ending_amount_cents: 2_100_00) # a corrupted top-level balance
      report = described_class.new(organization, month(y2026, 4))
      expect(report.difference).to eq(aud(-100))
      expect(report).not_to be_balanced
    end

    it "stores nothing" do
      expect { described_class.new(organization, month(y2027, 11)).total("asset") }.not_to change(TudlaAccounting::Balance, :count)
    end
  end

  describe TudlaAccounting::Reports::ProfitAndLoss do
    it "shows income and expenses moved during a month or a year" do
      march = described_class.new(organization, month(y2026, 3))
      expect(rows(march, "income")).to eq([ [ "4000", 0, aud(1_500) ], [ "4090", 0, aud(-100) ] ])
      expect(march.net_profit).to eq(aud(1_400))

      year = described_class.new(organization, y2026)
      expect(rows(year, "expense")).to eq([ [ "6000", 0, aud(650) ], [ "6100", 1, aud(400) ], [ "6200", 1, aud(250) ] ])
      expect(year.total("income")).to eq(aud(1_400))
      expect(year.net_profit).to eq(aud(750))

      expect(described_class.new(organization, y2027).net_profit).to eq(aud(600))
    end
  end

  describe TudlaAccounting::Reports::TrialBalance do
    def tb_rows(report) = report.rows.map { |row| [ row.account.code, row.debit, row.credit ] }

    it "lists each account's own balance in debit and credit columns, which total the same" do
      report = described_class.new(organization, month(y2026, 4))

      expect(tb_rows(report)).to eq([
        [ "1010", aud(8_000), nil ], [ "1500", aud(4_000), nil ], [ "1505", nil, aud(1_250) ],
        [ "2000", nil, aud(2_000) ], [ "3100", nil, aud(8_000) ],
        [ "4000", nil, aud(1_500) ], [ "4090", aud(100), nil ], [ "6100", aud(400), nil ], [ "6200", aud(250), nil ]
      ])
      expect([ report.total_debits, report.total_credits ]).to eq([ aud(12_750), aud(12_750) ])
      expect(report).to be_balanced
    end

    it "counts postings made directly to a parent account once" do
      post("1000", "3100", 50, Time.zone.local(2026, 4, 2)) # straight to the Assets parent
      report = described_class.new(organization, month(y2026, 4))

      expect(tb_rows(report)).to include([ "1000", aud(50), nil ])
      expect(report).to be_balanced
    end

    it "balances in a later year with retained earnings carried" do
      report = described_class.new(organization, month(y2027, 2))
      expect(tb_rows(report)).to include([ "3900", nil, aud(750) ], [ "4000", nil, aud(600) ])
      expect(report).to be_balanced
    end

    it "shows when debits and credits differ" do
      TudlaAccounting::Balance.get(account("2000"), month(y2026, 4)).update!(ending_amount_cents: 2_100_00)
      expect(described_class.new(organization, month(y2026, 4))).not_to be_balanced
    end
  end
end
