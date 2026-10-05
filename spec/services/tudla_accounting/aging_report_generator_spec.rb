require "rails_helper"
require_relative "../../support/entry_sources"

RSpec.describe TudlaAccounting::AgingReportGenerator, type: :service do
  include_context "with entry source models"

  let(:organization) { create(:organization, currency: "USD") }
  let(:acme) { create(:organization, name: "Acme (customer)") }
  let(:globex) { create(:organization, name: "Globex (customer)") }
  let(:as_of) { Date.new(2026, 6, 30) }

  before do
    TudlaAccounting.configuration.related_party_method = :customer
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash", category: "asset" },
      { code: "1100", name: "Accounts Receivable", category: "asset" },
      { code: "2100", name: "Accounts Payable", category: "liability" },
      { code: "4000", name: "Sales", category: "income" },
      { code: "5000", name: "Purchases", category: "expense" }
    ], organization)
  end

  def usd(amount) = Money.from_amount(amount, "USD")
  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)

  def post_entry(lines, on:, **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: on, **attrs)
    lines.each do |code, tally, amount|
      entry.details.build(account: account(code), tally: tally, amount_cents: usd(amount).cents, currency: "USD", organization: organization)
    end
    entry.save!
    entry.post(on)
    entry
  end

  def invoice(amount, customer:, due:, on: Time.zone.local(2026, 1, 10))
    post_entry([ [ "1100", :debit, amount ], [ "4000", :credit, amount ] ], on: on,
               source: Invoice.create!(due_date: due && Time.zone.local(due.year, due.month, due.day), customer: customer))
  end

  def payment(invoice_entry, amount, on:)
    post_entry([ [ "1000", :debit, amount ], [ "1100", :credit, amount ] ], on: on, source: Payment.create!, related: invoice_entry)
  end

  def report(type = :receivable, date = as_of)
    described_class.call(organization: organization, report_type: type, as_of_date: date)
  end

  it "buckets each open amount by days past due, as of the date" do
    invoice(100, customer: acme, due: Date.new(2026, 7, 15))  # not yet due
    invoice(200, customer: acme, due: Date.new(2026, 6, 30))  # due today
    invoice(300, customer: acme, due: Date.new(2026, 6, 20))  # 10 days
    invoice(400, customer: acme, due: Date.new(2026, 5, 16))  # 45 days
    invoice(500, customer: acme, due: Date.new(2026, 4, 16))  # 75 days
    invoice(600, customer: acme, due: Date.new(2026, 3, 1))   # 121 days
    invoice(700, customer: acme, due: nil)                    # no due date

    expect(report[:totals]).to eq(current: usd(1_000), days_1_30: usd(300), days_31_60: usd(400),
                                  days_61_90: usd(500), days_over_90: usd(600), total: usd(2_800))
  end

  it "groups by related party, with a summary and the lines behind it" do
    acme_invoice = invoice(100, customer: acme, due: Date.new(2026, 6, 20))
    invoice(250, customer: globex, due: Date.new(2026, 7, 31))

    result = report
    acme_key = "Organization_#{acme.id}"

    expect(result[:summary].keys).to contain_exactly(acme_key, "Organization_#{globex.id}")
    expect(result[:summary][acme_key]).to include(related_party: acme, total: usd(100))
    expect(result[:summary][acme_key][:aging_buckets]).to include(days_1_30: usd(100), current: usd(0), total: usd(100))
    expect(result[:details][acme_key].sole).to include(entry: acme_invoice, source: acme_invoice.source, outstanding: usd(100),
                                                       days_outstanding: 10, aging_bucket: :days_1_30)
    expect(result).to include(as_of_date: as_of, report_type: :receivable)
  end

  it "shows what is still owed after payments, and leaves out what is fully paid" do
    part_paid = invoice(300, customer: acme, due: Date.new(2026, 6, 1))
    fully_paid = invoice(200, customer: acme, due: Date.new(2026, 6, 1))
    payment(part_paid, 120, on: Time.zone.local(2026, 2, 1))
    payment(fully_paid, 200, on: Time.zone.local(2026, 2, 1))

    expect(report[:totals][:total]).to eq(usd(180))
    expect(report[:details].values.flatten.map { |line| line[:entry] }).to eq([ part_paid ])
  end

  it "reports a past date as it stood then: later invoices left out, later payments added back" do
    early = invoice(300, customer: acme, due: Date.new(2026, 3, 31), on: Time.zone.local(2026, 3, 1))
    invoice(500, customer: acme, due: Date.new(2026, 5, 31), on: Time.zone.local(2026, 4, 15)) # after 31 March
    payment(early, 300, on: Time.zone.local(2026, 4, 10))                                        # paid after 31 March

    march = report(:receivable, Date.new(2026, 3, 31))
    expect(march[:totals]).to include(current: usd(300), total: usd(300))
    expect(report[:totals]).to include(days_1_30: usd(500), total: usd(500)) # 30 June: the March invoice is paid
  end

  it "reports payables from bills, reduced by disbursements" do
    bill = post_entry([ [ "5000", :debit, 400 ], [ "2100", :credit, 400 ] ], on: Time.zone.local(2026, 2, 1),
                      source: Bill.create!(due_date: Time.zone.local(2026, 5, 1), customer: globex))
    post_entry([ [ "2100", :debit, 150 ], [ "1000", :credit, 150 ] ], on: Time.zone.local(2026, 3, 1), source: Disbursement.create!, related: bill)
    invoice(999, customer: acme, due: Date.new(2026, 5, 1))

    payables = report(:payable)
    expect(payables[:totals]).to include(days_31_60: usd(250), total: usd(250))
    expect(payables[:summary].keys).to eq([ "Organization_#{globex.id}" ])
  end

  it "only includes the organization's own amounts" do
    invoice(100, customer: acme, due: Date.new(2026, 6, 1))
    other = create(:organization)
    expect(described_class.call(organization: other, report_type: :receivable, as_of_date: as_of)[:totals][:total]).to eq(Money.new(0, other.currency))
  end

  it "groups under the organization when no related party method is configured" do
    TudlaAccounting.configuration.related_party_method = nil
    invoice(100, customer: acme, due: Date.new(2026, 6, 1))
    expect(report[:summary].keys).to eq([ "Organization_#{organization.id}" ])
  end

  it "reports in the organization's currency" do
    organization.update!(currency: "AUD")
    expect(report[:totals][:total]).to eq(Money.new(0, "AUD"))
  end

  it "returns empty results when nothing is owed" do
    result = report
    expect(result[:summary]).to eq({})
    expect(result[:totals]).to eq(current: usd(0), days_1_30: usd(0), days_31_60: usd(0), days_61_90: usd(0), days_over_90: usd(0), total: usd(0))
  end

  it "rejects an unknown report type" do
    expect { described_class.call(organization: organization, report_type: :invalid) }
      .to raise_error(ArgumentError, "Invalid report_type: invalid. Must be :receivable or :payable")
  end
end
