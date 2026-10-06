require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "General ledger and cash flow pages", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, currency: "AUD") }

  before { sign_in_as(organization) }

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def month(number) = year.children.order(:from_date)[number - 1]
  def total(name) = css_select("[data-total=#{name}]").first.text.squish

  it "asks for a financial year first" do
    [ routes.reports_general_ledger_path, routes.reports_cash_flow_path ].each do |path|
      get path
      expect(response.body).to include("No financial year yet.")
    end
  end

  context "with activity" do
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

    before do
      TudlaAccounting::AccountsCreator.call([
        { code: "1010", name: "Bank", category: "asset" }, { code: "1500", name: "Equipment", category: "asset" },
        { code: "3000", name: "Capital", category: "equity" }, { code: "4000", name: "Sales", category: "income" }
      ], organization)
      [ [ "1010", "3000", 1_000_00, 1 ], [ "1010", "4000", 250_00, 2 ], [ "1500", "1010", 400_00, 2 ] ].each do |debit, credit, cents, month_number|
        at = Time.zone.local(2026, month_number, 10)
        entry = build(:tudla_accounting_entry, organization: organization, transacted_at: at, particulars: "#{debit}/#{credit}")
        entry.details.build(account: account(debit), tally: :debit, amount_cents: cents, currency: "AUD", organization: organization)
        entry.details.build(account: account(credit), tally: :credit, amount_cents: cents, currency: "AUD", organization: organization)
        entry.save!
        entry.post(at)
      end
    end

    describe "the general ledger" do
      it "shows this month by default, account by account with running balances" do
        travel_to(Time.zone.local(2026, 2, 15)) { get routes.reports_general_ledger_path }
        expect(response.body).to include("1 Feb 2026 to 28 Feb 2026")
        bank = css_select("table").find { |table| table.text.include?("1010 - Bank") }
        expect(bank.css("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }).to eq([
          [ "1 Feb 2026", "Opening balance", "", "", "1,000.00" ], [ "10 Feb 2026", "1010/4000", "250.00", "", "1,250.00" ],
          [ "10 Feb 2026", "1500/1010", "", "400.00", "850.00" ], [ "28 Feb 2026", "Closing balance", "", "", "850.00" ]
        ])
        expect([ total("debits"), total("credits") ]).to eq([ "650.00", "650.00" ])
      end

      it "narrows to an account and downloads as CSV" do
        get routes.reports_general_ledger_path(account_id: account("1500").id, from_id: month(1).id, thru_id: month(2).id)
        expect(css_select("table thead th a").map(&:text)).to eq([ "1500 - Equipment" ])
        expect(css_select("a[href*='.csv']").first["href"]).to include("account_id=#{account('1500').id}")

        get routes.reports_general_ledger_path(format: :csv, account_id: account("1500").id, from_id: month(1).id, thru_id: month(2).id)
        expect(response.media_type).to eq("text/csv")
        expect(response.headers["Content-Disposition"]).to include("general-ledger-2026-01-01-to-2026-02-28.csv")
        expect(CSV.parse(response.body).map { |row| row[3] }).to eq([ "Entry", "Opening balance", "1500/1010", "Closing balance" ])
      end

      it "says when nothing happened, and refuses another organization's account" do
        get routes.reports_general_ledger_path(account_id: account("4000").id, from_id: month(1).id, thru_id: month(1).id)
        expect(response.body).to include("Nothing posted and no balances in this time.")
        get routes.reports_general_ledger_path(account_id: create(:tudla_accounting_account, organization: create(:organization)).id)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "the cash flow statement" do
      before { account("1500").update!(cash_flow_activity: :investing) }

      it "asks which accounts are cash until they are chosen or configured" do
        get routes.reports_cash_flow_path
        expect(response.body).to include("Choose the cash accounts above")
      end

      it "shows the year to date by activity for the configured cash accounts, and that it reconciles" do
        TudlaAccounting.configuration.cash_account_codes = %w[1010]
        travel_to(Time.zone.local(2026, 2, 15)) { get routes.reports_cash_flow_path }

        expect(response.body).to include("1 Jan 2026 to 28 Feb 2026", "The change in cash is fully explained")
        expect([ total("opening"), total("operating"), total("investing"), total("financing"), total("net_change"), total("closing") ])
          .to eq([ "0.00", "250.00", "(400.00)", "1,000.00", "850.00", "850.00" ])
        expect(css_select("#cash_account_ids option[selected]").map(&:text)).to eq([ "1010 - Bank" ])
      end

      it "takes chosen cash accounts and months" do
        get routes.reports_cash_flow_path(cash_account_ids: [ account("1010").id ], from_id: month(2).id, thru_id: month(2).id)
        expect([ total("opening"), total("net_change"), total("closing") ]).to eq([ "1,000.00", "(150.00)", "850.00" ])
        expect(response.body).to include("No cash moved.") # financing in February
      end

      it "shows an unexplained difference if the balances disagree with the lines" do
        TudlaAccounting::Balance.find_by(account: account("1010"), period: month(2)).update_columns(ending_amount_cents: 900_00)
        get routes.reports_cash_flow_path(cash_account_ids: [ account("1010").id ], from_id: month(2).id, thru_id: month(2).id)
        expect(response.body).to include("Unexplained difference of 50.00")
      end
    end

    it "sets an account's cash flow activity on its form" do
      account("1500").update!(cash_flow_activity: :investing)
      get routes.edit_account_path(account("1500"))
      expect(css_select("#account_cash_flow_activity option[selected]").text).to eq("Investing")
      patch routes.account_path(account("1500")), params: { account: { cash_flow_activity: "financing" } }
      expect(account("1500").cash_flow_activity).to eq("financing")
      patch routes.account_path(account("1500")), params: { account: { cash_flow_activity: "" } }
      expect(account("1500").cash_flow_activity).to be_nil
    end
  end
end
