require "rails_helper"

RSpec.describe Demo::PesoSeeder do
  around { |example| travel_to(Time.zone.local(2026, 6, 15, 9)) { example.run } }

  let(:organization) { described_class.call(entries: 30) }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def this_month = TudlaAccounting::Period.leaf_periods_for_date(organization, Time.current).first

  it "seeds Demo Pilipinas Inc.'s books in pesos once, balanced, beside the others" do
    demo_gmbh = Demo::EuroSeeder.call(entries: 30)

    expect(organization).to have_attributes(name: "Demo Pilipinas Inc.", currency: "PHP")
    expect(described_class.call).to eq(organization)
    expect(Demo::EuroSeeder.call).to eq(demo_gmbh)
    expect(TudlaAccounting::Entry.where(organization: organization).where(posted_at: nil)).to be_empty
    expect(TudlaAccounting::BalanceRebuilder.new(organization).differences).to be_empty
    expect(TudlaAccounting::Reports::BalanceSheet.new(organization, this_month)).to be_balanced
  end

  it "charges VAT at 12% on its sales, posted and invoiced, and shows pesos as ₱" do
    vat = TudlaAccounting::TaxCode.find_by!(organization: organization, code: "VAT12")
    sales = TudlaAccounting::Detail.where(tax_code: vat).includes(:entry).group_by(&:entry).values.reject { |lines| lines.one? }
    expect(sales).not_to be_empty
    expect(sales.map { |lines| lines.partition { |line| line.tax_role == "tax" }.map { |part| part.sum(&:amount_cents) } }).to all(satisfy { |tax, net| tax == (net * BigDecimal("0.12")).floor })

    sampaguita = TudlaAccounting::Document.find_by!(organization: organization, contact: TudlaAccounting::Contact.find_by!(name: "Sampaguita Foods Inc."))
    expect(TudlaAccounting::MoneyFormatter.labelled(sampaguita.total, organization)).to eq("₱56,112.00") # 45,000.00 plus 6 × 850.00, and 12% VAT
  end

  it "invoices Acme in dollars, zero-rated, at their own rates, the first paid at a better one" do
    acme = TudlaAccounting::Contact.find_by!(organization: organization, name: "Acme Inc.")
    invoices = TudlaAccounting::Document.where(organization: organization, contact: acme).order(:issued_on)
    expect(invoices.map { |invoice| [ invoice.currency, invoice.exchange_rate, invoice.total ] })
      .to eq([ [ "USD", BigDecimal("62.85"), Money.new(2_800_00, "USD") ], [ "USD", BigDecimal("63.10"), Money.new(2_800_00, "USD") ] ])
    expect(invoices.flat_map { |invoice| invoice.lines.map { |line| line.tax_code.code } }).to eq(%w[VATZR VATZR])
    expect(invoices.with_open_cents.map(&:payment_status)).to eq(%w[paid unpaid])
    expect(account("1100-USD")).to have_attributes(currency: "USD", parent: account("1100"))
    expect(TudlaAccounting::Balance.peek(account("4900"), this_month).ending_amount_cents).to eq(1_540_00) # (63.40 - 62.85) × 2,800.00 gained
  end

  it "numbers the invoices in date order" do
    invoices = TudlaAccounting::Document.where(organization: organization).sales.order(:number)
    expect(invoices.pluck(:number_label)).to eq((1..6).map { |number| format("INV-%04d", number) })
    expect(invoices.map(&:issued_on)).to eq(invoices.map(&:issued_on).sort)
  end

  it "has a 2550Q mapped to its VAT codes, with last quarter's filed" do
    filed = TudlaAccounting::FiledTaxReturn.find_by!(organization: organization)
    expect(filed.form.name).to eq("2550Q")
    expect([ filed.from_date, filed.thru_date ].map { |date| date.in_time_zone(Time.zone).to_date }).to eq([ Date.new(2026, 1, 1), Date.new(2026, 3, 31) ])
    figures = TudlaAccounting::TaxReturnCalculator.call(filed.form, from: filed.from_date, thru: filed.thru_date)[:boxes].to_h { |row| [ row.box.label, row.amount ] }
    expect(figures.values_at("31A", "31B")).to all(be_positive)
    expect(figures["32A"]).to eq(Money.new(175_980_00, "PHP")) # Acme's March invoice, $2,800.00 at 62.85
    expect(figures["15"]).to eq(figures["31B"] - figures["44B"]) # no input VAT that quarter: the demo's one bill is this month's
  end

  it "has customers and a supplier owing" do
    aging = TudlaAccounting::AgingReportGenerator.call(organization: organization, report_type: :receivable, as_of_date: Date.current)
    expect(aging[:summary].values.map { |party| party[:related_party].name }).to contain_exactly("Acme Inc.", "Sampaguita Foods Inc.")
    bill = TudlaAccounting::Document.find_by!(organization: organization, kind: "bill")
    expect(bill).to have_attributes(status: "approved", total: Money.new(28_000_00, "PHP"))
    expect(TudlaAccounting::PayRun.due(organization, currency: "PHP")).to eq([ bill ])
  end
end
