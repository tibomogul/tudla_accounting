require "rails_helper"
require_relative "../../support/entry_sources"

RSpec.describe TudlaAccounting::PartyStatement, type: :service do
  include_context "with entry source models"

  let(:organization) { create(:organization, currency: "AUD") }
  let(:globex) { create(:organization, name: "Globex") }
  let(:initech) { create(:organization, name: "Initech") }

  before do
    TudlaAccounting.configuration.related_party_method = :customer
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash", category: "asset" },
      { code: "1100", name: "Accounts Receivable", category: "asset", role: "receivable", children: [
        { code: "1100-EUR", name: "Accounts Receivable - EUR", category: "asset", currency: "EUR" } ] },
      { code: "2100", name: "Accounts Payable", category: "liability", role: "payable" },
      { code: "4000", name: "Sales", category: "income" }, { code: "4100", name: "Sales returns", category: "income" },
      { code: "4950", name: "Realized FX Gain", category: "income", role: "realized_fx_gain" },
      { code: "5000", name: "Purchases", category: "expense" }
    ], organization)
  end

  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def on(month, day) = Time.zone.local(2026, month, day)

  def post(lines, at:, particulars:, **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: particulars, transacted_at: at, **attrs)
    lines.each do |code, tally, amount, fx|
      line = entry.details.build(account: account(code), tally: tally, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
      line.build_foreign_exchange(other_currency: "EUR", other_currency_cents: (BigDecimal(fx[0].to_s) * 100).to_i, rate: BigDecimal(fx[1])) if fx
    end
    entry.save!
    entry.post(at)
    entry
  end

  def invoice(name, amount, at:, due: nil, customer: globex)
    post([ [ "1100-AUD", :debit, amount ], [ "4000", :credit, amount ] ], at: at, particulars: name, source: Invoice.create!(due_date: due, customer: customer))
  end

  def payment(name, amount, at:, related: nil)
    post([ [ "1000", :debit, amount ], [ "1100-AUD", :credit, amount ] ], at: at, particulars: name, source: Payment.create!(customer: globex), related: related)
  end

  def statement(from: Date.new(2026, 3, 1), thru: Date.new(2026, 3, 31), party: globex, type: :receivable)
    described_class.call(organization: organization, type: type, party: party, from: from, thru: thru)
  end

  def read(lines)
    lines.map { |line| [ line.date.day, line.kind, line.entry&.particulars, line.charge, line.credit, line.balance ] }
  end

  it "reads the same number of queries however many lines it has" do
    queries = lambda do
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { statement }
      count
    end
    # Before the run, part paid in it, and reversed in it.
    add = lambda do
      payment("Payment", 100, at: on(3, 5), related: invoice("Invoice", 300, at: on(2, 10), due: on(3, 12)))
      invoice("Invoice", 100, at: on(3, 15)).reverse!(on: Date.new(2026, 3, 20))
    end

    add.call
    few = queries.call
    2.times { add.call }

    expect(statement.closing).to eq(aud(600))
    expect(queries.call).to eq(few)
  end

  it "runs from the opening balance through the charges, credits and reversals in the dates to the closing balance" do
    first = invoice("Invoice 1", 300, at: on(2, 10), due: on(3, 12))
    second = invoice("Invoice 2", 200, at: on(3, 1), due: on(3, 31))
    payment("Payment 1", 250, at: on(3, 5), related: first)
    post([ [ "4100", :debit, 50 ], [ "1100-AUD", :credit, 50 ] ], at: on(3, 8), particulars: "Credit note 1", source: CreditNote.create!(customer: globex), related: second)
    invoice("Invoice 3", 100, at: on(3, 15)).reverse!(on: Date.new(2026, 3, 20))
    invoice("Invoice 4", 999, at: on(4, 2))
    invoice("Initech's", 70, at: on(3, 3), customer: initech)

    result = statement
    expect(result.opening).to eq(aud(300))
    expect(read(result.lines)).to eq([
      [ 1, "Invoice", "Invoice 2", aud(200), nil, aud(500) ], [ 5, "Payment", "Payment 1", nil, aud(250), aud(250) ],
      [ 8, "Credit note", "Credit note 1", nil, aud(50), aud(200) ], [ 15, "Invoice", "Invoice 3", aud(100), nil, aud(300) ],
      [ 20, "Reversal", "Reversal of: Invoice 3", nil, aud(100), aud(200) ]
    ])
    expect(result.lines.first.due_date.to_date).to eq(Date.new(2026, 3, 31))
    expect(result).to have_attributes(closing: aud(200), charges_total: aud(300), credits_total: aud(400), foreign?: false)
    expect(result.aging).to include(current: aud(150), days_1_30: aud(50), total: aud(200))
    expect(result.open_items.map { |line| [ line[:entry].particulars, line[:outstanding] ] }).to eq([ [ "Invoice 1", aud(50) ], [ "Invoice 2", aud(150) ] ])
  end

  it "takes up exchange differences on settlement before the closing balance" do
    value = ->(eur, rate) { (BigDecimal(eur.to_s) * BigDecimal(rate)).round(2) }
    inv = post([ [ "1100-EUR", :debit, value.call(100, "1.54"), [ 100, "1.54" ] ], [ "4000", :credit, value.call(100, "1.54") ] ], at: on(3, 1), particulars: "Invoice EUR",
               source: Invoice.create!(customer: globex))
    post([ [ "1000", :debit, value.call(100, "1.60") ], [ "1100-EUR", :credit, value.call(100, "1.60"), [ 100, "1.60" ] ] ], at: on(3, 10), particulars: "Payment EUR",
         source: Payment.create!(customer: globex), related: inv)

    result = statement
    expect(read(result.lines)).to eq([
      [ 1, "Invoice", "Invoice EUR", aud(154), nil, aud(154) ], [ 10, "Payment", "Payment EUR", nil, aud(160), aud(-6) ],
      [ 31, described_class::ADJUSTMENT, nil, aud(6), nil, aud(0) ]
    ])
    expect(result.lines.first(2).map(&:foreign)).to eq([ Money.new(100_00, "EUR"), Money.new(-100_00, "EUR") ])
    expect(result).to have_attributes(closing: aud(0), foreign?: true)
  end

  it "makes a supplier's from their bills and payments, with only an opening balance when nothing happened" do
    bill = post([ [ "5000", :debit, 80 ], [ "2100-AUD", :credit, 80 ] ], at: on(1, 5), particulars: "Bill 1", source: Bill.create!(customer: globex))
    post([ [ "2100-AUD", :debit, 30 ], [ "1000", :credit, 30 ] ], at: on(1, 20), particulars: "Paid", source: Disbursement.create!(customer: globex), related: bill)

    expect(read(statement(type: :payable, from: Date.new(2026, 1, 1), thru: Date.new(2026, 1, 31)).lines))
      .to eq([ [ 5, "Bill", "Bill 1", aud(80), nil, aud(80) ], [ 20, "Payment", "Paid", nil, aud(30), aud(50) ] ])
    quiet = statement(type: :payable)
    expect(quiet).to have_attributes(opening: aud(50), lines: [], closing: aud(50))
    expect(statement.closing).to eq(aud(0)) # nothing receivable
  end

  it "names an item whose source has no role (an imported open item) an invoice" do
    invoice("Invoice 1", 10, at: on(3, 2))
    TudlaAccounting.configuration.carrying_amount_sources = {}
    expect(statement.lines.sole.kind).to eq("Invoice")
  end

  it "lists the parties with receivables or payables by name, keyed for URLs" do
    invoice("Invoice 1", 10, at: on(3, 2), customer: initech)
    invoice("Invoice 2", 10, at: on(3, 2))
    expect(described_class.parties(organization, :receivable)).to eq([ globex, initech ])
    expect(described_class.parties(organization, :payable)).to eq([])
    expect(described_class.key(globex)).to eq("Organization_#{globex.id}")
    expect(described_class.party_name(create(:organization, name: ""))).to match(/\AOrganization #\d+\z/)
  end

  it "refuses an unknown type or dates the wrong way round" do
    expect { statement(type: :both) }.to raise_error(ArgumentError, "Invalid type: both. Must be :receivable or :payable")
    expect { statement(from: Date.new(2026, 4, 1)) }.to raise_error(ArgumentError, "The statement must start on or before its end")
  end
end
