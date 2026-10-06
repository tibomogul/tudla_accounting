require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/entry_sources"

RSpec.describe "Report pages", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }

  before { sign_in_as(organization) }

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def total(name) = css_select("[data-total='#{name}']").first&.text&.squish

  def post_entry(debit, credit, amount, on, **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: on, particulars: "#{debit}/#{credit}", **attrs)
    entry.details.build(account: account(debit), tally: :debit, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
    entry.details.build(account: account(credit), tally: :credit, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
    entry.save!
    entry.post(on)
    entry
  end

  it "lists the reports" do
    get routes.reports_path
    expect(css_select("a.tc-card p.font-semibold").map(&:text)).to eq([ "Balance sheet", "Profit and loss", "Trial balance", "Receivables aging", "Payables aging", "Tax summary" ])
  end

  it "asks for a financial year before showing statements" do
    %i[reports_balance_sheet_path reports_profit_and_loss_path reports_trial_balance_path].each do |path|
      get routes.public_send(path)
      expect(response.body).to include("No financial year yet.")
    end
  end

  context "with a year of activity" do
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
    let(:march) { year.children.order(:from_date).third }

    before do
      TudlaAccounting::AccountsCreator.call([
        { code: "1010", name: "Cash", category: "asset" },
        { code: "3100", name: "Capital", category: "equity" },
        { code: "4000", name: "Sales", category: "income" },
        { code: "6100", name: "Rent", category: "expense" }
      ], organization)
      post_entry("1010", "3100", 1_000, Time.zone.local(2026, 1, 5))
      post_entry("1010", "4000", 500, Time.zone.local(2026, 3, 5))
      post_entry("6100", "1010", 200, Time.zone.local(2026, 4, 5))
    end

    it "shows the balance sheet at the end of the month containing today, balanced" do
      travel_to(Time.zone.local(2026, 4, 15)) { get routes.reports_balance_sheet_path }

      expect(response.body).to include("As at 30 Apr 2026", "Balanced: assets equal liabilities plus equity")
      expect([ total("asset"), total("liability"), total("equity"), total("current_year_earnings"), total("liabilities_and_equity") ])
        .to eq([ "1,300.00", "0.00", "1,000.00", "300.00", "1,300.00" ])
      expect(css_select("#section-liability").first.ancestors("table").first.text).to include("Nothing to report.")
      expect(css_select("a[href='#{routes.account_path(account('1010'), year_id: year.id)}']").text).to eq("Cash")
    end

    it "shows the balance sheet at the end of a chosen month" do
      get routes.reports_balance_sheet_path(period_id: march.id)
      expect(total("current_year_earnings")).to eq("500.00")
      expect(css_select("#period_id option[selected]").text).to eq("Mar 2026 (to 31 Mar 2026)")
    end

    it "shows profit and loss for the current year by default, or a chosen month" do
      travel_to(Time.zone.local(2026, 4, 15)) { get routes.reports_profit_and_loss_path }
      expect([ total("income"), total("expense"), total("net_profit") ]).to eq([ "500.00", "200.00", "300.00" ])
      expect(response.body).to include("Net profit", "1 Jan 2026 to 31 Dec 2026")
      expect(css_select("#period_id option").map(&:text)).to include("Year 2026", "Mar 2026 (to 31 Mar 2026)")

      get routes.reports_profit_and_loss_path(period_id: year.children.order(:from_date).fourth.id)
      expect([ total("income"), total("net_profit") ]).to eq([ "0.00", "(200.00)" ])
      expect(response.body).to include("Net loss")
    end

    it "shows the trial balance with equal totals" do
      get routes.reports_trial_balance_path(period_id: march.id)

      rows = css_select("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
      expect(rows).to eq([ [ "1010", "Cash", "1,500.00", "" ], [ "3100", "Capital", "", "1,000.00" ], [ "4000", "Sales", "", "500.00" ],
                           [ "Total", "1,500.00", "1,500.00" ] ])
      expect(response.body).to include("Debits equal credits")
    end

    it "shows when the books are out of balance" do
      TudlaAccounting::Balance.get(account("3100"), march).update!(ending_amount_cents: 1_100_00)
      get routes.reports_balance_sheet_path(period_id: march.id)
      expect(response.body).to include("Out of balance by 100.00")
      get routes.reports_trial_balance_path(period_id: march.id)
      expect(response.body).to include("Debits and credits differ by 100.00")
    end

    it "falls back to the latest month before today, then the earliest" do
      travel_to(Time.zone.local(2027, 6, 1)) { get routes.reports_trial_balance_path }
      expect(response.body).to include("As at 31 Dec 2026")

      travel_to(Time.zone.local(2025, 6, 1)) { get routes.reports_trial_balance_path }
      expect(response.body).to include("As at 31 Jan 2026")
    end

    it "refuses another organization's period, and a year where a month is expected" do
      get routes.reports_balance_sheet_path(period_id: TudlaAccounting::PeriodCreator.call(create(:organization), 2026).children.first.id)
      expect(response).to have_http_status(:not_found)

      get routes.reports_trial_balance_path(period_id: year.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  context "aging" do
    include_context "with entry source models"

    let(:customer) { create(:organization, name: "Globex") }

    before do
      TudlaAccounting.configuration.related_party_method = :customer
      TudlaAccounting::PeriodCreator.call(organization, 2026)
      TudlaAccounting::AccountsCreator.call([
        { code: "1000", name: "Cash", category: "asset" }, { code: "1100", name: "Receivables", category: "asset" },
        { code: "2100", name: "Payables", category: "liability" }, { code: "4000", name: "Sales", category: "income" }
      ], organization)
      post_entry("1100", "4000", 300, Time.zone.local(2026, 3, 1), particulars: "Invoice 7",
           source: Invoice.create!(due_date: Time.zone.local(2026, 3, 31), customer: customer))
    end

    it "shows what customers owe by how overdue it is, with the lines behind it" do
      get routes.reports_receivables_path(as_of: "2026-05-15")

      expect(response.body).to include("Owed to Acme as at 15 May 2026", "Globex")
      expect([ total("days_31_60"), total("total") ]).to eq([ "300.00", "300.00" ])
      line = css_select("details tbody tr").first.css("td").map { |cell| cell.text.squish }
      expect(line).to eq([ "Invoice 7", "31 Mar 2026", "45", "300.00" ])
    end

    it "shows nothing outstanding for payables" do
      get routes.reports_payables_path
      expect(response.body).to include("Payables aging", "Nothing outstanding.")
      expect(total("total")).to eq("0.00")
    end

    it "names a party without a name by its type and id" do
      expect(helper_name(Object.new.tap { |o| o.define_singleton_method(:id) { 4 } })).to eq("Object #4")
    end

    def helper_name(party) = Class.new { include TudlaAccounting::ReportsHelper }.new.related_party_name(party)
  end
end
