require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "Accounts", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:year) { TudlaAccounting::PeriodCreator.call(organization, Date.current.year) }

  before { sign_in_as(organization) }

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def text_of(selector) = css_select(selector).map { |node| node.text.squish }

  def chart
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Current Assets", category: "asset", children: [
        { code: "1010", name: "Cash", category: "asset" },
        { code: "1020", name: "Bank - EUR", category: "asset", currency: "EUR" }
      ] },
      { code: "1500", name: "Equipment", category: "asset" },
      { code: "1505", name: "Accumulated Depreciation", category: "asset", contra_account: "1500" },
      { code: "3000", name: "Capital", category: "equity" },
      { code: "4000", name: "Sales", category: "income" }
    ], organization)
  end

  def post_entry(debit, credit, amount, on)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: "#{debit} from #{credit}", transacted_at: on)
    entry.details.build(account: account(debit), tally: :debit, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
    entry.details.build(account: account(credit), tally: :credit, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
    entry.save!
    entry.post(on)
  end

  def in_year(month, day = 10) = Time.zone.local(Date.current.year, month, day)

  describe "GET /accounts" do
    it "lists the chart by category, sub-accounts under their parent, with this year's closing balances" do
      chart
      year
      post_entry("1010", "3000", 500, in_year(2))
      post_entry("1010", "4000", 120.5, in_year(3))

      expect { get routes.accounts_path }.not_to change(TudlaAccounting::Balance, :count) # reading stores nothing

      expect(response).to have_http_status(:ok)
      expect(text_of("thead th[id^=category]")).to eq(%w[Assets Equity Income])
      assets = css_select("section")[0]
      expect(assets.css("tbody td.font-mono").map(&:text)).to eq(%w[1000 1010 1020 1500 1505])
      expect(assets.at_css("tr:nth-child(2) div")["style"]).to eq("padding-left: 1.25rem")
      expect(assets.text).to include("contra 1500", "EUR")
      expect(assets.css("tbody tr:nth-child(1) .tc-num").text).to eq("620.50") # parent includes its sub-accounts
      expect(css_select("section")[1].css(".tc-num").last.text).to eq("500.00")
      expect(assets.css("tbody tr:nth-child(5) .tc-num").text).to eq("0.00") # contra 1505, no balance yet
    end

    it "shows contra accounts as deductions from their category" do
      chart
      year
      post_entry("1500", "3000", 1000, in_year(2))
      post_entry("3000", "1505", 250, in_year(3)) # depreciation credited to the contra account

      get routes.accounts_path

      rows = css_select("section")[0].css("tbody tr").to_h { |row| [ row.at_css("td.font-mono").text, row.at_css(".tc-num").text.squish ] }
      expect(rows.values_at("1500", "1505")).to eq([ "1,000.00", "(250.00)" ])
    end

    it "shows carried-forward balances for a year without postings yet" do
      chart
      year
      post_entry("1010", "3000", 500, in_year(2))
      TudlaAccounting::PeriodCreator.call(organization, Date.current.year + 1)

      travel_to(Time.zone.local(Date.current.year + 1, 1, 15)) { get routes.accounts_path }

      expect(response.body).to include("Closing balances for #{Date.current.year + 1}")
      expect(css_select("section")[0].css("tbody tr:nth-child(2) .tc-num").text).to eq("500.00")
    end

    it "shows dashes without a financial year, and only the organization's accounts" do
      chart
      create(:tudla_accounting_account, code: "9999", name: "Someone else's", organization: create(:organization))

      get routes.accounts_path

      expect(response.body).to include("No financial year yet")
      expect(response.body).not_to include("Someone else")
      expect(text_of("tbody .tc-num").uniq).to eq([ "—" ])
    end

    it "invites creating the first account" do
      get routes.accounts_path
      expect(response.body).to include("No accounts yet", "Create the first account")
    end
  end

  describe "GET /accounts/:id" do
    before do
      chart
      year
      post_entry("1010", "3000", 500, in_year(2))
      post_entry("1020", "4000", 80, in_year(3, 5))
      post_entry("4000", "1010", 30, in_year(3, 20)) # a refund
    end

    it "shows the account's place in the chart and its monthly balances" do
      expect { get routes.account_path(account("1010")) }.not_to change(TudlaAccounting::Balance, :count)

      expect(response.body).to include("1010 - Cash", "1000 - Current Assets")
      months = css_select("table")[0].css("tbody tr")
      expect(months.size).to eq(13)
      expect(months[1].css("td").map(&:text).map(&:squish)).to eq([ "Feb #{Date.current.year}", "0.00", "500.00", "500.00" ])
      expect(months[2].css("td").map(&:text).map(&:squish)).to eq([ "Mar #{Date.current.year}", "500.00", "(30.00)", "470.00" ])
      expect(months.last.css("td").map(&:text).map(&:squish)).to eq([ "Year", "0.00", "470.00", "470.00" ])
    end

    it "lists the ledger with a running balance, including sub-accounts for a parent" do
      get routes.account_path(account("1000"))

      ledger = css_select("table")[1].css("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
      expect(ledger.map { |row| row.values_at(2, 3, 4, 5) }).to eq([
        [ "1010", "500.00", "", "500.00" ], [ "1020", "80.00", "", "580.00" ], [ "1010", "", "30.00", "550.00" ]
      ])
      expect(response.body).to include("(including sub-accounts)")
    end

    it "filters the ledger by date, keeping the running balance from the start of the year" do
      get routes.account_path(account("1010"), from: in_year(3, 1).to_date, thru: in_year(3, 31).to_date)

      ledger = css_select("table")[1].css("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
      expect(ledger).to eq([ [ in_year(3, 20).strftime("%-d %b %Y"), "4000 from 1010", "", "30.00", "470.00" ] ])
    end

    it "says when nothing was posted in the dates" do
      get routes.account_path(account("1010"), from: in_year(6, 1).to_date)
      expect(response.body).to include("Nothing posted in these dates.")
    end

    it "pages long ledgers" do
      55.times { |i| post_entry("1010", "3000", 1, in_year(4, 1 + (i % 28))) } # 57 lines on 1010 in all
      get routes.account_path(account("1010"), page: 2)
      expect(css_select("table")[1].css("tbody tr").size).to eq(7)
      expect(css_select("nav.tc-pagination a[aria-current=page]").text).to eq("2")
    end

    it "lets you pick another year" do
      other = TudlaAccounting::PeriodCreator.call(organization, Date.current.year - 1)
      get routes.account_path(account("1010"), year_id: other.id)
      expect(response.body).to include("Balances for #{Date.current.year - 1}", "Nothing posted.")
    end

    it "offers deleting only an unused account" do
      get routes.account_path(account("1010"))
      expect(response.body).not_to include(">Delete<")

      get routes.account_path(account("1505")) # no postings, sub-accounts, or contra accounts of its own
      expect(css_select("form[action='#{routes.account_path(account('1505'))}'] button").text).to eq("Delete")
    end

    it "does not show another organization's account" do
      stranger = create(:tudla_accounting_account, organization: create(:organization))
      get routes.account_path(stranger)
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("Not found", "doesn't exist in Acme's books")
    end
  end

  it "suggests creating a year when there is none" do
    chart
    get routes.account_path(account("1010"))
    expect(response.body).to include("No financial year yet.", routes.new_period_path)
  end

  describe "creating" do
    before { chart }

    it "starts in the organization's currency, or under a chosen parent" do
      get routes.new_account_path
      expect(css_select("#account_currency").first["value"]).to eq("AUD")

      get routes.new_account_path(parent_id: account("1000").id, category: "asset")
      expect(css_select("#account_parent_id option[selected]").text).to eq("1000 - Current Assets")
      expect(css_select("#account_category option[selected]").text).to eq("Asset")
    end

    it "creates an account under a parent, as a contra account" do
      post routes.accounts_path, params: { account: { code: "1030", name: "Petty cash", category: "asset", currency: "aud",
                                                      parent_id: account("1000").id, contra_account_id: "" } }

      created = account("1030")
      expect(response).to redirect_to(routes.account_path(created))
      expect(created).to have_attributes(parent: account("1000"), currency: "AUD", contra_account: nil)
      follow_redirect!
      expect(response.body).to include("Account 1030 - Petty cash was created.")
    end

    it "shows what is wrong" do
      post routes.accounts_path, params: { account: { code: "1010", name: "", category: "liability", currency: "ZZZ", parent_id: account("1000").id } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(text_of(".tc-error-text")).to include("Code has already been taken", "Name can't be blank", "Currency is not a known currency code")
      expect(response.body).to include("Attributes are not compatible with parent")
    end

    it "refuses another organization's account as parent or contra" do
      stranger = create(:tudla_accounting_account, organization: create(:organization))
      post routes.accounts_path, params: { account: { code: "1030", name: "X", category: "asset", parent_id: stranger.id } }
      expect(response).to have_http_status(:not_found)

      post routes.accounts_path, params: { account: { code: "1030", name: "X", category: "asset", contra_account_id: stranger.id } }
      expect(response).to have_http_status(:not_found)
      expect(account("1030")).to be_nil
    end
  end

  describe "editing" do
    before do
      chart
      year
    end

    it "updates an unused account's structure" do
      get routes.edit_account_path(account("1500"))
      expect(css_select("#account_parent_id option").map(&:text)).not_to include("1500 - Equipment")

      patch routes.account_path(account("1500")), params: { account: { name: "Plant & equipment", parent_id: account("1000").id } }

      expect(response).to redirect_to(routes.account_path(account("1500")))
      expect(account("1500")).to have_attributes(name: "Plant & equipment", parent: account("1000"))
    end

    it "locks the structure once the account has postings" do
      post_entry("1010", "3000", 500, in_year(2))

      get routes.edit_account_path(account("1010"))
      expect(response.body).to include("fixed now that the account has postings")
      expect(css_select("#account_category").first["disabled"]).to eq("disabled")

      patch routes.account_path(account("1010")), params: { account: { category: "liability" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("can&#39;t change once the account has postings")

      patch routes.account_path(account("1010")), params: { account: { name: "Cash at bank" } }
      expect(account("1010").name).to eq("Cash at bank")
    end
  end

  describe "deleting" do
    before do
      chart
      year
    end

    it "deletes an unused account" do
      delete routes.account_path(account("4000"))
      expect(response).to redirect_to(routes.accounts_path)
      expect(account("4000")).to be_nil
    end

    it "refuses an account with postings, sub-accounts or contra accounts" do
      post_entry("1010", "3000", 500, in_year(2))

      [ "1010", "1000", "1500" ].each do |code|
        delete routes.account_path(account(code))
        expect(response).to redirect_to(routes.account_path(account(code)))
        expect(flash[:alert]).to eq("Only an account with no postings, sub-accounts or contra accounts can be deleted")
      end
    end
  end
end
