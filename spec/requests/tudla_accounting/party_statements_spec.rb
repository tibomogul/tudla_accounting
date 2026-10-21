require "rails_helper"
require_relative "../../support/entry_sources"
require_relative "../../support/sign_in"

RSpec.describe "Customer and supplier statements", type: :request do
  include_context "with entry source models"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:globex) { create(:organization, name: "Globex") }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting.configuration.related_party_method = :customer
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash", category: "asset" },
      { code: "1100", name: "Accounts Receivable", category: "asset", role: "receivable", children: [
        { code: "1100-EUR", name: "Accounts Receivable - EUR", category: "asset", currency: "EUR" } ] },
      { code: "2100", name: "Accounts Payable", category: "liability", role: "payable" },
      { code: "4000", name: "Sales", category: "income" }, { code: "5000", name: "Purchases", category: "expense" }
    ], organization)
    @first = post_entry([ [ "1100", :debit, 300 ], [ "4000", :credit, 300 ] ], at: Time.zone.local(2026, 2, 10), particulars: "Invoice 1",
                  source: Invoice.create!(customer: globex, due_date: Time.zone.local(2026, 3, 12)), reference: "INV-1")
    post_entry([ [ "1000", :debit, 250 ], [ "1100", :credit, 250 ] ], at: Time.zone.local(2026, 3, 5), particulars: "Payment 1", source: Payment.create!(customer: globex), related: @first)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def key(party = globex) = "Organization_#{party.id}"
  def rows(selector) = css_select("#{selector} tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }

  def post_entry(lines, at:, particulars:, **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: particulars, transacted_at: at, **attrs)
    lines.each do |code, tally, amount, fx|
      line = entry.details.build(account: account(code), tally: tally, amount_cents: amount * 100, currency: "AUD", organization: organization)
      line.build_foreign_exchange(other_currency: "EUR", other_currency_cents: fx * 100, rate: BigDecimal("1.5")) if fx
    end
    entry.save!
    entry.post(at)
    entry
  end

  it "asks for a customer, then shows their activity for last month by default" do
    get routes.reports_statement_path
    expect(response.body).to include("Choose a customer to see their statement.")
    expect(css_select("select[name=party] option").map(&:text)).to eq([ "Choose one", "Globex" ])
    expect(css_select("input[name=from]").first["value"]).to eq("2026-03-01")

    get routes.reports_statement_path(party: key)
    expect(css_select("[data-party]").map(&:text)).to eq([ "Globex" ])
    expect(rows("[data-activity]")).to eq([
      [ "1 Mar 2026", "Opening balance", "", "300.00" ],
      [ "5 Mar 2026", "Payment", "#2", "Payment 1", "", "", "250.00", "50.00" ],
      [ "31 Mar 2026", "Closing balance", "0.00", "250.00", "50.00" ]
    ])
    expect(css_select("[data-activity] thead th").map(&:text)).to include("Invoiced", "Paid or credited")
    expect(rows("[data-aging]")).to eq([ [ "0.00", "50.00", "0.00", "0.00", "0.00" ] ])
    expect(css_select("[data-amount-due]").first.text.squish).to eq("Amount due at 31 Mar 2026 AUD 50.00")
  end

  it "shows what is open at the end, with foreign amounts, and the dates either way round" do
    post_entry([ [ "1100-EUR", :debit, 150, 100 ], [ "4000", :credit, 150 ] ], at: Time.zone.local(2026, 3, 20), particulars: "Invoice EUR",
         source: Invoice.create!(customer: globex, due_date: Time.zone.local(2026, 4, 30)))
    get routes.reports_statement_path(party: key, show: "open_items", from: "2026-03-31", thru: "2026-01-01")
    expect(response.body).to include("Open items at 31 Mar 2026")
    expect(rows("[data-open-items]")).to eq([
      [ "10 Feb 2026", "INV-1", "Invoice 1", "12 Mar 2026", "19", "", "300.00", "50.00" ],
      [ "20 Mar 2026", "#3", "Invoice EUR", "30 Apr 2026", "", "€100,00", "150.00", "150.00" ]
    ])

    get routes.reports_statement_path(party: key, from: "2026-03-01", thru: "2026-03-31")
    expect(rows("[data-activity]")[2]).to eq([ "20 Mar 2026", "Invoice", "#3", "Invoice EUR", "30 Apr 2026", "€100,00", "150.00", "", "200.00" ])
  end

  it "makes a supplier's, says when there are none, and asks again when the type changes" do
    get routes.reports_statement_path(type: "payable")
    expect(response.body).to include("No suppliers have bills yet.")
    post_entry([ [ "5000", :debit, 80 ], [ "2100", :credit, 80 ] ], at: Time.zone.local(2026, 3, 2), particulars: "Bill 1", source: Bill.create!(customer: globex))
    get routes.reports_statement_path(type: "payable", party: key)
    expect(css_select("[data-activity] thead th").map(&:text)).to include("Billed")
    expect(css_select("[data-amount-due]").first.text.squish).to start_with("Balance owing")

    get routes.reports_statement_path(type: "payable", party: key(create(:organization)))
    expect(response.body).to include("Choose a supplier")
  end

  it "says when the customer is in credit, and reads dates it can't as last month" do
    post_entry([ [ "1000", :debit, 100 ], [ "1100", :credit, 100 ] ], at: Time.zone.local(2026, 3, 6), particulars: "Payment 2", source: Payment.create!(customer: globex))
    get routes.reports_statement_path(party: key, from: "soon")
    expect(css_select("input[name=from]").first["value"]).to eq("2026-03-01")
    expect(css_select("[data-amount-due]").first.text.squish).to eq("In credit at 31 Mar 2026 AUD 50.00")
  end

  it "downloads the activity or the open items" do
    get routes.reports_statement_path(party: key, format: :csv)
    expect(response.headers["Content-Disposition"]).to include("statement-globex-2026-03-01-to-2026-03-31.csv")
    expect(CSV.parse(response.body)).to eq([
      [ "Date", "Type", "Reference", "Details", "Due", "Invoiced", "Paid or credited", "Balance" ],
      [ "2026-03-01", nil, nil, "Opening balance", nil, nil, nil, "300.00" ],
      [ "2026-03-05", "Payment", "#2", "Payment 1", nil, nil, "250.00", "50.00" ],
      [ "2026-03-31", nil, nil, "Closing balance", nil, "0.00", "250.00", "50.00" ]
    ])

    post_entry([ [ "1100-EUR", :debit, 150, 100 ], [ "4000", :credit, 150 ] ], at: Time.zone.local(2026, 3, 20), particulars: "Invoice EUR", source: Invoice.create!(customer: globex))
    get routes.reports_statement_path(party: key, show: "open_items", format: :csv)
    expect(response.headers["Content-Disposition"]).to include("statement-globex-open-items-2026-03-31.csv")
    csv = CSV.parse(response.body)
    expect(csv.first).to eq([ "Date", "Reference", "Details", "Due", "Days overdue", "Currency", "Foreign outstanding", "Amount", "Outstanding" ])
    expect(csv[1]).to eq([ "2026-02-10", "INV-1", "Invoice 1", "2026-03-12", "19", nil, nil, "300.00", "50.00" ])
    expect(csv[2]).to eq([ "2026-03-20", "#3", "Invoice EUR", nil, nil, "EUR", "100.00", "150.00", "150.00" ])
    expect(csv.last).to eq([ nil, nil, "Closing balance", nil, nil, nil, nil, nil, "200.00" ])

    get routes.reports_statement_path(format: :csv)
    expect(response).to have_http_status(:not_found)
  end

  it "shows every customer's statement with something to send, one to a page, and downloads them together" do
    initech = create(:organization, name: "Initech")
    umbrella = create(:organization, name: "Umbrella")
    paid = post_entry([ [ "1100", :debit, 40 ], [ "4000", :credit, 40 ] ], at: Time.zone.local(2026, 1, 5), particulars: "Initech invoice", source: Invoice.create!(customer: initech))
    post_entry([ [ "1000", :debit, 40 ], [ "1100", :credit, 40 ] ], at: Time.zone.local(2026, 1, 9), particulars: "Initech pays", source: Payment.create!(customer: initech), related: paid)
    post_entry([ [ "1100", :debit, 70 ], [ "4000", :credit, 70 ] ], at: Time.zone.local(2026, 3, 9), particulars: "Umbrella invoice", source: Invoice.create!(customer: umbrella))

    get routes.reports_statement_path
    expect(css_select("a").map { |link| link["href"] }).to include(routes.reports_statements_path(type: :receivable, from: "2026-03-01", thru: "2026-03-31"))
    get routes.reports_statements_path
    expect(css_select("[data-statement] [data-party]").map(&:text)).to eq(%w[Globex Umbrella]) # Initech had nothing in March
    expect(response.body).to include("2 to send")
    expect(css_select("select[name=party]")).to be_empty

    get routes.reports_statements_path(format: :csv)
    expect(response.headers["Content-Disposition"]).to include("statements-customers-2026-03-01-to-2026-03-31.csv")
    csv = CSV.parse(response.body)
    expect(csv.first).to eq([ "Customer", "Date", "Type", "Reference", "Details", "Due", "Invoiced", "Paid or credited", "Balance" ])
    expect(csv.drop(1).map { |row| [ row[0], row[4], row[-1] ] }).to eq([
      [ "Globex", "Opening balance", "300.00" ], [ "Globex", "Payment 1", "50.00" ], [ "Globex", "Closing balance", "50.00" ],
      [ "Umbrella", "Opening balance", "0.00" ], [ "Umbrella", "Umbrella invoice", "70.00" ], [ "Umbrella", "Closing balance", "70.00" ]
    ])

    get routes.reports_statements_path(show: "open_items", from: "2026-02-01", thru: "2026-02-28")
    expect(css_select("[data-statement] [data-party]").map(&:text)).to eq(%w[Globex]) # Initech had paid
    get routes.reports_statements_path(show: "open_items", format: :csv)
    expect(CSV.parse(response.body).first.first(3)).to eq([ "Customer", "Date", "Reference" ])
  end

  it "says when no supplier has a statement to send" do
    get routes.reports_statements_path(type: "payable")
    expect(response.body).to include("No supplier has a balance or activity in these dates.")
    get routes.reports_statements_path(type: "payable", show: "open_items")
    expect(response.body).to include("No supplier has anything open at the end.")
    expect(css_select("a").map { |link| link["href"] }).to include(routes.reports_statement_path(type: :payable, from: "2026-03-01", thru: "2026-03-31", show: "open_items"))
  end

  it "is linked from the aging report" do
    get routes.reports_receivables_path(as_of: "2026-03-31")
    expect(css_select("a").map { |link| link["href"] }).to include(routes.reports_statement_path(type: :receivable, party: key, from: "2026-03-01", thru: "2026-03-31"))
  end
end
