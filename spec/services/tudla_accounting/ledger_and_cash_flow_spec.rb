require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe "General ledger and cash flow", type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash and bank", category: "asset", children: [
        { code: "1011", name: "Cheque account", category: "asset" }, { code: "1012", name: "Savings", category: "asset" } ] },
      { code: "1100", name: "Receivables", category: "asset" },
      { code: "1500", name: "Equipment", category: "asset" },
      { code: "2500", name: "Loan", category: "liability" },
      { code: "3000", name: "Capital", category: "equity" },
      { code: "4000", name: "Sales", category: "income" },
      { code: "6000", name: "Rent", category: "expense" }
    ], organization)
    account("1500").update!(cash_flow_activity: :investing)
    account("2500").update!(cash_flow_activity: :financing)
    TudlaAccounting::StartingBalanceCreator.call(organization, Date.new(2026, 1, 1), [
      { account_id: account("1010").id, amount_cents: 500_00, children: [ { account_id: account("1011").id, amount_cents: 500_00 } ] },
      { account_id: account("3000").id, amount_cents: 500_00 }
    ], "AUD")

    post("1011", "3000", 1_000_00, 1, 5, "Capital in")     # financing (equity)
    post("1011", "4000", 300_00, 2, 1, "Cash sale")        # operating
    post("1100", "4000", 200_00, 2, 2, "Credit sale")      # no cash
    post("1011", "1100", 150_00, 2, 20, "Customer paid")   # operating (receivables)
    post("1500", "1011", 800_00, 3, 3, "Laptop")           # investing
    post("1011", "2500", 2_000_00, 3, 4, "Loan drawn")     # financing
    post("6000", "1011", 100_00, 3, 10, "Rent")            # operating
    post("1012", "1011", 400_00, 3, 15, "To savings")      # between cash accounts
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def month(number) = year.children.order(:from_date)[number - 1]
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")

  def post(debit, credit, cents, month_number, day, particulars)
    at = Time.zone.local(2026, month_number, day)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: at, particulars: particulars)
    entry.details.build(account: account(debit), tally: :debit, amount_cents: cents, currency: "AUD", organization: organization)
    entry.details.build(account: account(credit), tally: :credit, amount_cents: cents, currency: "AUD", organization: organization)
    entry.save!
    entry.post(at)
  end

  describe "the general ledger" do
    let(:ledger) { TudlaAccounting::Reports::GeneralLedger.new(organization, from: month(2), thru: month(3)) }

    it "lists each posting account's opening balance, lines with a running balance, and closing balance" do
      cheque = ledger.accounts.find { |section| section.account.code == "1011" }
      expect(cheque.opening).to eq(aud(1_500))
      expect(cheque.lines.map { |l| [ l.entry.particulars, l.debit, l.credit, l.balance ] }).to eq([
        [ "Cash sale", aud(300), nil, aud(1_800) ], [ "Customer paid", aud(150), nil, aud(1_950) ], [ "Laptop", nil, aud(800), aud(1_150) ],
        [ "Loan drawn", aud(2_000), nil, aud(3_150) ], [ "Rent", nil, aud(100), aud(3_050) ], [ "To savings", nil, aud(400), aud(2_650) ]
      ])
      expect(cheque.closing).to eq(aud(2_650))
      expect(ledger.accounts.map { |section| section.account.code }).to eq(%w[1011 1012 1100 1500 2500 3000 4000 6000]) # not the parent 1010
      expect(ledger.accounts.find { |s| s.account.code == "3000" }).to have_attributes(opening: aud(1_500), lines: [], closing: aud(1_500))
      expect(ledger.total_debits).to eq(ledger.total_credits)
    end

    it "narrows to chosen accounts and leaves out accounts with nothing" do
      narrowed = TudlaAccounting::Reports::GeneralLedger.new(organization, from: month(4), thru: month(4), account_ids: [ account("6000").id, account("1012").id ])
      expect(narrowed.accounts.map { |s| [ s.account.code, s.opening, s.lines.size, s.closing ] }).to eq([ [ "1012", aud(400), 0, aud(400) ], [ "6000", aud(100), 0, aud(100) ] ])
      expect(TudlaAccounting::Reports::GeneralLedger.new(organization, from: month(1), thru: month(1), account_ids: [ account("6000").id ]).accounts).to be_empty
    end

    it "writes a CSV with opening and closing rows" do
      csv = CSV.parse(TudlaAccounting::Reports::GeneralLedger.new(organization, from: month(3), thru: month(3), account_ids: [ account("6000").id ]).to_csv)
      expect(csv).to eq([ [ "Date", "Account code", "Account", "Entry", "Debit", "Credit", "Balance" ],
                          [ "2026-03-01", "6000", "Rent", "Opening balance", nil, nil, "0.00" ],
                          [ "2026-03-10", "6000", "Rent", "Rent", "100.00", nil, "100.00" ],
                          [ "2026-03-31", "6000", "Rent", "Closing balance", nil, nil, "100.00" ] ])
    end
  end

  describe "the cash flow statement" do
    def flow(from: month(1), thru: month(3), cash_accounts: nil) = TudlaAccounting::Reports::CashFlow.new(organization, from: from, thru: thru, cash_accounts: cash_accounts)

    it "needs to know which accounts are cash" do
      expect(flow).not_to be_configured
      TudlaAccounting.configuration.cash_account_codes = %w[1010]
      expect(flow.cash_accounts).to eq([ account("1010") ])
    end

    it "explains the change in cash by activity, leaving out moves between cash accounts" do
      result = flow(cash_accounts: [ account("1010"), account("1011") ]) # 1011 is inside 1010: counted once
      expect(result.cash_accounts).to eq([ account("1010") ])
      expect(result.sections.transform_values { |rows| rows.map { |r| [ r.account.code, r.amount ] } }).to eq(
        "operating" => [ [ "1100", aud(150) ], [ "4000", aud(300) ], [ "6000", aud(-100) ] ],
        "investing" => [ [ "1500", aud(-800) ] ],
        "financing" => [ [ "2500", aud(2_000) ], [ "3000", aud(1_000) ] ]
      )
      expect([ result.total("operating"), result.total("investing"), result.total("financing") ]).to eq([ aud(350), aud(-800), aud(3_000) ])
      expect([ result.opening, result.net_change, result.closing ]).to eq([ aud(500), aud(2_550), aud(3_050) ])
      expect(result).to be_reconciles
    end

    it "starts from net profit and adjusts for balance-sheet changes on the indirect method, arriving at the same totals" do
      direct = flow(cash_accounts: [ account("1010") ])
      indirect = TudlaAccounting::Reports::CashFlow.new(organization, from: month(1), thru: month(3), cash_accounts: [ account("1010") ], method: :indirect)

      expect(indirect.flow_method).to eq(:indirect)
      expect(indirect.sections.transform_values { |rows| rows.map { |r| [ r.label || r.account.code, r.amount ] } }).to eq(
        "operating" => [ [ "Net profit", aud(400) ], [ "1100", aud(-50) ] ], # sales 500 - rent 100; receivables grew by 50
        "investing" => [ [ "1500", aud(-800) ] ],
        "financing" => [ [ "2500", aud(2_000) ], [ "3000", aud(1_000) ] ]
      )
      expect(TudlaAccounting::Reports::CashFlow::ACTIVITIES.map { |a| indirect.total(a) }).to eq(TudlaAccounting::Reports::CashFlow::ACTIVITIES.map { |a| direct.total(a) })
      expect([ indirect.net_change, indirect.closing ]).to eq([ aud(2_550), aud(3_050) ])
      expect(indirect).to be_reconciles
    end

    it "refuses an unknown method" do
      expect { TudlaAccounting::Reports::CashFlow.new(organization, from: month(1), thru: month(1), method: :magic) }
        .to raise_error(ArgumentError, "method must be one of direct, indirect")
    end

    it "treats a move to an account outside cash as cash going out" do
      result = flow(from: month(3), thru: month(3), cash_accounts: [ account("1011") ])
      expect(result.sections["operating"].map { |r| [ r.account.code, r.amount ] }).to eq([ [ "1012", aud(-400) ], [ "6000", aud(-100) ] ])
      expect(result).to be_reconciles
    end

    it "inherits an account's activity from its parent, and defaults by category" do
      TudlaAccounting::AccountsCreator.call([ { code: "1600", name: "Vehicles", category: "asset", children: [ { code: "1610", name: "Van", category: "asset" } ] } ], organization)
      account("1600").update!(cash_flow_activity: :investing)
      expect(account("1610").cash_flow_section).to eq("investing")
      expect(account("3000").cash_flow_section).to eq("financing")
      expect(account("1100").cash_flow_section).to eq("operating")
    end
  end
end
