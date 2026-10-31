require "rails_helper"

RSpec.describe Demo::EuroSeeder do
  around { |example| travel_to(Time.zone.local(2026, 6, 15, 9)) { example.run } }

  let(:organization) { described_class.call(entries: 30) }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  it "seeds Demo GmbH's books in euros once, balanced, beside Demo Co's" do
    demo_co = Demo::Seeder.call(entries: 30)

    expect(organization).to have_attributes(name: "Demo GmbH", currency: "EUR")
    expect(described_class.call).to eq(organization)
    expect(Demo::Seeder.call).to eq(demo_co)
    expect(TudlaAccounting::Entry.where(organization: organization).where(posted_at: nil)).to be_empty
    expect(TudlaAccounting::BalanceRebuilder.new(organization).differences).to be_empty
    month = TudlaAccounting::Period.leaf_periods_for_date(organization, Time.current).first
    expect(TudlaAccounting::Reports::BalanceSheet.new(organization, month)).to be_balanced
  end

  it "writes its amounts as the euro is written" do
    expect(TudlaAccounting::NumberFormat.for(organization)).to eq(TudlaAccounting::NumberFormat::STYLES.fetch(:comma))
    rossi = TudlaAccounting::Document.find_by!(organization: organization, contact: TudlaAccounting::Contact.find_by!(name: "Rossi S.p.A."))
    expect(TudlaAccounting::MoneyFormatter.number(rossi.total, organization)).to eq("1.647,68") # 149,70 plus 10,48 VAT and 1.250,00 plus 237,50
  end

  it "invoices Acme in dollars at their own rates, the first paid at a better one" do
    acme = TudlaAccounting::Contact.find_by!(organization: organization, name: "Acme Inc.")
    expect(acme.currency).to eq("USD")
    invoices = TudlaAccounting::Document.where(organization: organization, contact: acme).order(:issued_on)
    expect(invoices.map { |invoice| [ invoice.currency, invoice.exchange_rate, invoice.total ] })
      .to eq([ [ "USD", BigDecimal("0.915"), Money.new(2_800_00, "USD") ], [ "USD", BigDecimal("0.923"), Money.new(2_800_00, "USD") ] ])
    expect(invoices.with_open_cents.map(&:payment_status)).to eq(%w[paid unpaid])
    expect(account("1100-USD")).to have_attributes(currency: "USD", parent: account("1100"))
    expect(TudlaAccounting::Balance.peek(account("4900"), TudlaAccounting::Period.leaf_periods_for_date(organization, Time.current).first).ending_amount_cents)
      .to eq(44_80) # (0,9310 - 0,9150) × 2.800,00 gained
  end

  it "numbers the invoices in date order" do
    invoices = TudlaAccounting::Document.where(organization: organization).sales.order(:number)
    expect(invoices.pluck(:number_label)).to eq((1..6).map { |number| format("INV-%04d", number) })
    expect(invoices.map(&:issued_on)).to eq(invoices.map(&:issued_on).sort)
  end

  it "has customers and a supplier owing" do
    aging = TudlaAccounting::AgingReportGenerator.call(organization: organization, report_type: :receivable, as_of_date: Date.current)
    expect(aging[:summary].values.map { |party| party[:related_party].name }).to contain_exactly("Acme Inc.", "Rossi S.p.A.")
    bill = TudlaAccounting::Document.find_by!(organization: organization, kind: "bill")
    expect(bill).to have_attributes(status: "approved", total: Money.new(1_761_20, "EUR"))
    expect(TudlaAccounting::PayRun.due(organization, currency: "EUR")).to eq([ bill ])
  end
end
