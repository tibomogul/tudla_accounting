require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Setup", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "USD") }

  before { sign_in_as(organization) }

  def accounts = TudlaAccounting::Account.where(organization: organization)
  def account(code) = accounts.find_by(code: code)
  def upload(name, type = "text/csv") = Rack::Test::UploadedFile.new(file_fixture(name), type)

  it "asks for a financial year before loading a chart" do
    get routes.setup_path
    expect(response.body).to include("first: opening balances need a period")
    expect(response.body).to include("No month has ended yet.")
  end

  context "with a financial year" do
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

    it "shows the forms and which settings they need" do
      TudlaAccounting.configuration.receivable_account_code = "1020"
      get routes.setup_path

      expect(css_select("#opening_date").first["value"]).to eq("2026-01-01")
      expect(css_select("#date_prior").first["value"]).to eq("2025-12-31")
      expect(response.body).to include("<code class=\"text-xs\">1020</code>", "not set")
    end

    it "loads a chart of accounts from a CSV" do
      post routes.setup_chart_of_accounts_path, params: { file: upload("coa_saas_services.csv"), opening_date: "2026-01-01" }

      expect(response).to redirect_to(routes.accounts_path)
      expect(flash[:notice]).to eq("Chart of accounts loaded: 81 new accounts, with opening balances.")
      expect(TudlaAccounting::Balance.find_by(account: account("1011"), period: year).starting_amount).to eq(Money.from_amount(25_000, "USD"))
    end

    it "loads one from an Excel file, and overwrites only when asked" do
      xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      post routes.setup_chart_of_accounts_path, params: { file: upload("coa_saas_services.xlsx", xlsx), opening_date: "2026-01-01" }
      expect(accounts.count).to eq(81)

      post routes.setup_chart_of_accounts_path, params: { file: upload("coa_saas_services.xlsx", xlsx), opening_date: "2026-01-01" }
      expect(flash[:alert]).to eq("The chart of accounts was not loaded: Account 1000 already exists. Enable overwrite mode to reuse existing accounts.")

      post routes.setup_chart_of_accounts_path, params: { file: upload("coa_saas_services.xlsx", xlsx), opening_date: "2026-01-01", overwrite: "1" }
      expect(flash[:notice]).to eq("Chart of accounts loaded: 0 new accounts, with opening balances.")
    end

    it "reports problems" do
      post routes.setup_chart_of_accounts_path, params: { file: upload("carrying_amounts.csv").tap { |file| file.instance_variable_set(:@original_filename, "chart.txt") }, opening_date: "2026-01-01" }
      expect(flash[:alert]).to eq("The chart of accounts was not loaded: Upload a .csv or .xlsx file")

      post routes.setup_chart_of_accounts_path, params: { file: upload("coa_saas_services.csv"), opening_date: "2026-02-01" }
      expect(flash[:alert]).to start_with("The chart of accounts was not loaded: Period")

      post routes.setup_chart_of_accounts_path, params: { opening_date: "2026-01-01" }
      expect(flash[:alert]).to start_with("The chart of accounts was not loaded: param is missing").and(end_with(": file"))
      expect(accounts.count).to eq(0)
    end

    context "with receivables and payables accounts" do
      before do
        TudlaAccounting.configuration.receivable_account_code = "1020"
        TudlaAccounting.configuration.payable_account_code = "2011"
        post routes.setup_chart_of_accounts_path, params: { file: upload("coa_saas_services.csv"), opening_date: "2026-01-01" }
      end

      it "offers income and expense accounts to offset against" do
        get routes.setup_path
        expect(css_select("#sales_account_code option").map(&:text)).to include("4011 - SaaS Subscription Fees")
        expect(css_select("#purchase_account_code option").map(&:text)).to include("5011 - Hosting Costs")
        expect(css_select("#sales_account_code option").map(&:text)).not_to include("1011 - Operating Cash Account")
      end

      it "imports the items open at the cut-over" do
        post routes.setup_open_items_path, params: { file: upload("carrying_amounts.csv"), date_prior: "2025-12-31",
                                                      sales_account_code: "4011", purchase_account_code: "5011" }

        expect(response).to redirect_to(routes.reports_receivables_path)
        expect(flash[:notice]).to eq("Imported 3 open items.")
        expect(TudlaAccounting::CarryingAmount.count).to eq(3)
      end

      it "reports problems importing" do
        post routes.setup_open_items_path, params: { file: upload("carrying_amounts.csv"), date_prior: "2025-12-31", sales_account_code: "4011" }
        expect(flash[:alert]).to eq("The open items were not imported: No purchase account code given")
        expect(TudlaAccounting::CarryingAmount.count).to eq(0)
      end
    end

    context "revaluing" do
      let(:march) { year.children.order(:from_date).third }

      before do
        TudlaAccounting.configuration.receivable_account_code = "1100"
        TudlaAccounting.configuration.carrying_amount_sources = { "TudlaAccounting::Period" => :receivable }
        TudlaAccounting.configuration.unrealized_fx_gain_account_code = "4900"
        TudlaAccounting::AccountsCreator.call([
          { code: "1100", name: "Receivables", category: "asset", children: [ { code: "1100-EUR", name: "Receivables EUR", category: "asset", currency: "EUR" } ] },
          { code: "4000", name: "Sales", category: "income" }, { code: "4900", name: "FX gains", category: "income" }
        ], organization)
        invoice = build(:tudla_accounting_entry, organization: organization, particulars: "Invoice", transacted_at: Time.zone.local(2026, 3, 1), source: year)
        line = invoice.details.build(account: account("1100-EUR"), tally: :debit, amount_cents: 154_00, currency: "USD", organization: organization)
        line.build_foreign_exchange(other_currency: "EUR", other_currency_cents: 100_00, rate: BigDecimal("1.54"))
        invoice.details.build(account: account("4000"), tally: :credit, amount_cents: 154_00, currency: "USD", organization: organization)
        invoice.save!
        invoice.post(invoice.transacted_at)
      end

      it "lists the months that have ended" do
        get routes.setup_path
        expect(css_select("#period_id option").first.text).to start_with("#{Date.current.prev_month.strftime('%b %Y')} (")
      end

      it "posts revaluation entries for a month end" do
        TudlaAccounting::ForexRate.create!(from: "EUR", to: "USD", year: 2026, month: 3, day: 31, rate: BigDecimal("1.60"))

        post routes.setup_revaluation_path, params: { period_id: march.id }

        expect(response).to redirect_to(routes.entries_path(q: "Revaluation"))
        expect(flash[:notice]).to eq("Posted 2 revaluation entries for 31 Mar 2026.")
      end

      it "says when there is nothing to revalue, or no rate" do
        post routes.setup_revaluation_path, params: { period_id: march.id }
        expect(flash[:alert]).to eq("The revaluation was not run: No EUR/USD rate for 2026-03-31 and no forex_rate_provider configured")

        TudlaAccounting::ForexRate.create!(from: "EUR", to: "USD", year: 2026, month: 3, day: 31, rate: BigDecimal("1.54"))
        post routes.setup_revaluation_path, params: { period_id: march.id }
        expect(flash[:notice]).to eq("Nothing to revalue at 31 Mar 2026.")
      end

      it "refuses another organization's month" do
        post routes.setup_revaluation_path, params: { period_id: TudlaAccounting::PeriodCreator.call(create(:organization), 2026).children.first.id }
        expect(flash[:alert]).to start_with("The revaluation was not run: Couldn't find")
      end
    end
  end
end
