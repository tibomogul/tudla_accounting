require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "Opening balances", type: :request do
  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before { sign_in_as(organization) }

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def opening(code, period = year) = TudlaAccounting::Balance.peek(account(code), period).starting_amount
  def input(code) = css_select("#amounts_#{account(code).id}").first

  it "asks for a financial year first" do
    get routes.setup_opening_balances_path
    expect(response.body).to include("first: opening balances go at the start of the first year")
  end

  it "won't save without a financial year" do
    patch routes.setup_opening_balances_path, params: { amounts: {} }
    expect(response).to redirect_to(routes.setup_path)
    expect(flash[:alert]).to eq("The opening balances were not saved: Create a financial year first")
  end

  it "asks for accounts first" do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    get routes.setup_opening_balances_path
    expect(response.body).to include("Add accounts", "first")
  end

  context "with a year and a chart of accounts" do
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

    before do
      TudlaAccounting::PeriodCreator.call(organization, 2027)
      TudlaAccounting::AccountsCreator.call([
        { code: "1000", name: "Assets", category: "asset", children: [
          { code: "1010", name: "Cash", category: "asset" },
          { code: "1500", name: "Equipment", category: "asset" },
          { code: "1505", name: "Accumulated Depreciation", category: "asset", contra_account: "1500" }
        ] },
        { code: "2000", name: "Loan", category: "liability" },
        { code: "3000", name: "Capital", category: "equity" }
      ], organization)
    end

    def save(amounts)
      patch routes.setup_opening_balances_path, params: { amounts: amounts.transform_keys { |code| account(code).id.to_s } }
    end

    it "lists every account, with inputs only for accounts without sub-accounts" do
      get routes.setup_opening_balances_path

      expect(response.body).to include("At the start of 2026 (1 Jan 2026), in AUD")
      expect(input("1000")).to be_nil
      expect(input("1010")["value"]).to eq("0.00")
      expect(input("1010")["data-side"]).to eq("debit")
      expect(input("1505")["data-side"]).to eq("credit") # a contra asset is deducted
      expect(input("2000")["data-side"]).to eq("credit")
      expect(response.body).to include("deducted")
    end

    it "saves balanced amounts at the start of the first year, parents adding up their sub-accounts" do
      save("1010" => "3,000", "1500" => "2000", "1505" => "500", "2000" => "1500", "3000" => "3000")

      expect(response).to redirect_to(routes.reports_balance_sheet_path(period_id: year.children.order(:from_date).first.id))
      expect(flash[:notice]).to eq("Opening balances saved at 1 Jan 2026.")
      expect(opening("1010")).to eq(aud(3_000))
      expect(opening("1505")).to eq(aud(500)) # on its own (credit) side
      expect(opening("1000")).to eq(aud(4_500))
      expect(opening("1010", TudlaAccounting::Period.roots.order(:from_date).last)).to eq(aud(3_000)) # carried into 2027
      expect(TudlaAccounting::Reports::BalanceSheet.new(organization, year.children.order(:from_date).first)).to be_balanced
    end

    it "shows what is there already, and replaces it, moving later balances with it" do
      save("1010" => "3000", "3000" => "3000")
      cash_march = TudlaAccounting::Balance.get(account("1010"), year.children.order(:from_date).third)

      get routes.setup_opening_balances_path
      expect(input("1010")["value"]).to eq("3000.00")
      expect(css_select("span[title^='The total of its sub-accounts']").first.text).to eq("3,000.00")

      save("1010" => "3500", "3000" => "3500")
      expect(opening("1010")).to eq(aud(3_500))
      expect(cash_march.reload.starting_amount).to eq(aud(3_500))
    end

    it "refuses amounts that don't balance or aren't numbers, keeping what was typed" do
      save("1010" => "3000", "3000" => "2000")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Debits (3,000.00) and credits (2,000.00) don&#39;t balance, in AUD")
      expect(input("1010")["value"]).to eq("3000.00")

      save("1010" => "lots", "3000" => "0")
      expect(response.body).to include("1010 - Cash: lots isn&#39;t an amount")
      expect(TudlaAccounting::Balance.count).to eq(0)
    end
  end

  it "is linked from setup" do
    get routes.setup_path
    expect(response.body).to include(routes.setup_opening_balances_path, "Enter opening balances")
  end
end
