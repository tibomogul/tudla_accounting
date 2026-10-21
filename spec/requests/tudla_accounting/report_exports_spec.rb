require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/entry_sources"

RSpec.describe "Report exports", type: :request do
  include_context "with entry source models"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:customer) { create(:organization, name: "=Globex") } # a name a spreadsheet would run as a formula
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    sign_in_as(organization)
    TudlaAccounting.configuration.related_party_method = :customer
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash", category: "asset" },
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2200", name: "GST", category: "liability" },
      { code: "3100", name: "Capital", category: "equity" },
      { code: "4000", name: "Sales", category: "income" },
      { code: "6100", name: "+Rent", category: "expense" }
    ], organization)
    @gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200"))
    team = TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department").dimension_values.create!(code: "OPS", name: "Ops")

    post_entry([ "1010", 1_000 ], [ "3100", 1_000 ], on: Time.zone.local(2026, 1, 5))
    post_entry([ "1100", 330 ], [ "4000", 300, { tax_code: @gst, tax_role: :base, tags: [ team ] } ], [ "2200", 30, { tax_code: @gst, tax_role: :tax } ],
               on: Time.zone.local(2026, 3, 1), source: Invoice.create!(due_date: Time.zone.local(2026, 3, 31), customer: customer))
    post_entry([ "6100", 200 ], [ "1010", 200 ], on: Time.zone.local(2026, 4, 5))
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def month(number) = year.children.order(:from_date).to_a[number - 1]
  def csv = CSV.parse(response.body)

  # Lines as [code, amount, extra detail attributes]; the first is a debit, the rest credits.
  def post_entry(debit, *credits, on:, **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: on, particulars: "Entry", **attrs)
    [ [ debit, :debit ], *credits.map { |credit| [ credit, :credit ] } ].each do |(code, amount, extra), tally|
      extra = (extra || {}).dup
      tags = extra.delete(:tags) || []
      line = entry.details.build(account: account(code), tally: tally, amount_cents: amount * 100, currency: "AUD", organization: organization, **extra)
      tags.each { |value| line.tags.build(dimension_value: value) }
    end
    entry.save!
    entry.post(on)
  end

  it "downloads the balance sheet, alone or compared, with a link from the page" do
    get routes.reports_balance_sheet_path(period_id: month(4).id)
    expect(css_select("a").map { |link| link["href"] }).to include("#{routes.reports_balance_sheet_path}.csv?period_id=#{month(4).id}")

    get routes.reports_balance_sheet_path(format: :csv, period_id: month(4).id)
    expect(response.media_type).to eq("text/csv")
    expect(response.headers["Content-Disposition"]).to include("balance-sheet-2026-04-30.csv")
    expect(csv.first).to eq([ "Section", "Code", "Account", "Level", "Apr 2026" ])
    expect(csv).to include([ "Assets", "1010", "Cash", "0", "800.00" ], [ "Assets", nil, "Total assets", nil, "1130.00" ],
                           [ nil, nil, "Total liabilities and equity", nil, "1130.00" ])

    get routes.reports_balance_sheet_path(format: :csv, period_id: month(4).id, compare: "previous")
    expect(csv.first).to eq([ "Section", "Code", "Account", "Level", "Apr 2026", "Mar 2026", "Change", "Change %" ])
    expect(csv).to include([ "Assets", "1010", "Cash", "0", "800.00", "1000.00", "-200.00", "-20.0" ],
                           [ "Liabilities", "2200", "GST", "0", "30.00", "30.00", "0.00", "0.0" ])
  end

  it "downloads the profit and loss month by month, with the year's total" do
    get routes.reports_profit_and_loss_path(format: :csv, period_id: year.id, compare: "months")
    expect(response.headers["Content-Disposition"]).to include("profit-and-loss-2026-01-01-to-2026-12-31.csv")
    expect(csv.first.last(2)).to eq([ "Dec 2026", "Total" ])
    expect(csv.find { |row| row[1] == "4000" }.values_at(4, 5, 6, -1)).to eq([ "0.00", "0.00", "300.00", "300.00" ])
    expect(csv.last).to eq([ nil, nil, "Net profit (loss)", nil, "0.00", "0.00", "300.00", "-200.00", *Array.new(8, "0.00"), "100.00" ])
  end

  it "keeps text a spreadsheet would run as a formula as text, and numbers as numbers" do
    get routes.reports_profit_and_loss_path(format: :csv, period_id: year.id)
    expect(csv.find { |row| row[1] == "6100" }).to eq([ "Expenses", "6100", "'+Rent", "0", "200.00" ])
    expect(csv.last).to eq([ nil, nil, "Net profit (loss)", nil, "100.00" ])
  end

  it "downloads the trial balance" do
    get routes.reports_trial_balance_path(format: :csv, period_id: month(4).id)
    expect(csv.first).to eq([ "Code", "Account", "Debit", "Credit" ])
    expect(csv).to include([ "1010", "Cash", "800.00", nil ], [ "3100", "Capital", nil, "1000.00" ])
    expect(csv.last).to eq([ nil, "Total", "1330.00", "1330.00" ])
  end

  it "downloads the receivables aging, an item per row in its bucket" do
    get routes.reports_receivables_path(format: :csv, as_of: "2026-05-15")
    expect(response.headers["Content-Disposition"]).to include("receivables-aging-2026-05-15.csv")
    expect(csv.first).to eq([ "Party", "Entry no.", "Entry", "Due", "Days overdue", "Current", "1–30 days", "31–60 days", "61–90 days", "Over 90 days", "Total" ])
    expect(csv.drop(1)).to eq([
      [ "'=Globex", "#2", "Entry", "2026-03-31", "45", nil, nil, "330.00", nil, nil, "330.00" ],
      [ "Total", nil, nil, nil, nil, "0.00", "0.00", "330.00", "0.00", "0.00", "330.00" ]
    ])
  end

  it "downloads the tax summary" do
    get routes.reports_tax_path(format: :csv, from_id: month(1).id, thru_id: month(4).id)
    expect(response.headers["Content-Disposition"]).to include("tax-summary-accrual-2026-01-01-to-2026-04-30.csv")
    expect(csv).to eq([
      [ "Code", "Name", "Kind", "Rate %", "Taxed amount", "Tax" ], [ "GST", "GST", "Sales", "10.0", "300.00", "30.00" ],
      [ nil, "Total sales", nil, nil, "300.00", "30.00" ], [ nil, "Total purchases", nil, nil, "0.00", "0.00" ],
      [ nil, "Net tax payable", nil, nil, nil, "30.00" ]
    ])
  end

  it "downloads profit and loss by dimension" do
    get routes.reports_by_dimension_path(format: :csv, from_id: month(1).id, thru_id: month(4).id)
    expect(response.headers["Content-Disposition"]).to include("profit-and-loss-by-dept-2026-01-01-to-2026-04-30.csv")
    expect(csv.first).to eq([ "Section", "Code", "Account", "Ops", "Untagged", "Total" ])
    expect(csv).to include([ "Income", "4000", "Sales", "300.00", "0.00", "300.00" ], [ "Expenses", "6100", "'+Rent", "0.00", "200.00", "200.00" ])
    expect(csv.last).to eq([ nil, nil, "Net profit (loss)", "300.00", "-200.00", "100.00" ])
  end

  it "downloads the cash flow once cash accounts are chosen" do
    get routes.reports_cash_flow_path(format: :csv, from_id: month(1).id, thru_id: month(4).id)
    expect(response).to have_http_status(:not_found)
    get routes.reports_cash_flow_path(from_id: month(1).id, thru_id: month(4).id)
    expect(response.body).not_to include("Download CSV")

    get routes.reports_cash_flow_path(format: :csv, from_id: month(1).id, thru_id: month(4).id, cash_account_ids: [ account("1010").id ])
    expect(csv.first).to eq([ "Section", "Code", "Account", "Amount" ])
    expect(csv).to include([ "Operating activities", "6100", "'+Rent", "-200.00" ], [ "Financing activities", "3100", "Capital", "1000.00" ],
                           [ nil, nil, "Cash at the start", "0.00" ], [ nil, nil, "Cash at the end", "800.00" ])
  end

  it "downloads a report as an Excel workbook when the host has caxlsx, and offers printing" do
    get routes.reports_trial_balance_path(period_id: month(4).id)
    expect(css_select("a").map { |link| link["href"] }).to include("#{routes.reports_trial_balance_path}.xlsx?period_id=#{month(4).id}")
    expect(css_select("button[data-action='print#print']").map(&:text)).to eq([ "Print or save as PDF" ])

    get routes.reports_trial_balance_path(format: :xlsx, period_id: month(4).id)
    expect(response.media_type).to eq("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    expect(response.headers["Content-Disposition"]).to include("trial-balance-2026-04-30.xlsx")
    expect(response.body).to start_with("PK") # a zip, as workbooks are

    get routes.reports_general_ledger_path(format: :xlsx, from_id: month(1).id, thru_id: month(4).id)
    expect(response.headers["Content-Disposition"]).to include("general-ledger-2026-01-01-to-2026-04-30.xlsx")
  end

  it "offers only CSV without caxlsx" do
    allow(TudlaAccounting).to receive(:xlsx?).and_return(false)
    get routes.reports_trial_balance_path(period_id: month(4).id)
    expect(css_select("a").map(&:text)).to include("Download CSV")
    expect(css_select("a").map(&:text)).not_to include("Excel")
    get routes.reports_trial_balance_path(format: :xlsx, period_id: month(4).id)
    expect(response).to have_http_status(:not_found)
  end

  it "has nothing to download without periods" do
    sign_in_as(create(:organization, name: "New Co", currency: "AUD"))
    get routes.reports_balance_sheet_path(format: :csv)
    expect(response).to have_http_status(:not_found)
    get routes.reports_general_ledger_path(format: :csv)
    expect(response).to have_http_status(:not_found)
  end
end
