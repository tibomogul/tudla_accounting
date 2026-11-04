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

  it "keeps its books of accounts, with money in and out of the bank in the cash journals, every page balanced" do
    books = TudlaAccounting::Reports::BooksOfAccounts.new(organization, from: TudlaAccounting::Period.leaf_periods_for_date(organization, Date.new(2026, 1, 1)).first, thru: this_month)
    pages = books.books.to_h { |book| [ book.key, book.pages ] }
    expect(pages.values_at("cash_receipts", "cash_disbursements", "sales", "general_ledger")).to all(be_present)
    expect(pages.except("general_ledger").values.flatten.map(&:balanced)).to all(be(true))
    rows = pages.values_at("cash_receipts", "sales").flatten.flat_map(&:rows).map(&:cells)
    expect(rows).to include(a_hash_including(particulars: start_with("Payment from Bayanihan Trading Corp."), receivable: be_positive),
                            a_hash_including(party: "Acme Inc.", zero_rated: be_positive))
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
    expect(invoices.pluck(:number_label)).to eq((1..8).map { |number| format("INV-%04d", number) })
    expect(invoices.map(&:issued_on)).to eq(invoices.map(&:issued_on).sort)
  end

  it "has a 2550Q mapped to its VAT codes, with last quarter's filed" do
    filed = TudlaAccounting::FiledTaxReturn.find_by!(organization: organization)
    expect(filed.form.name).to eq("2550Q")
    expect([ filed.from_date, filed.thru_date ].map { |date| date.in_time_zone(Time.zone).to_date }).to eq([ Date.new(2026, 1, 1), Date.new(2026, 3, 31) ])
    figures = TudlaAccounting::TaxReturnCalculator.call(filed.form, from: filed.from_date, thru: filed.thru_date)[:boxes].to_h { |row| [ row.box.label, row.amount ] }
    expect(figures.values_at("31A", "31B")).to all(be_positive)
    expect(figures["32A"]).to eq(Money.new(175_980_00, "PHP")) # Acme's March invoice, $2,800.00 at 62.85
    expect(figures["44A"]).to eq(Money.new(60_000_00, "PHP")) # Dakila's bill that quarter
    expect(figures["15"]).to eq(figures["31B"] - figures["44B"])
  end

  it "has customers and a supplier owing" do
    aging = TudlaAccounting::AgingReportGenerator.call(organization: organization, report_type: :receivable, as_of_date: Date.current)
    expect(aging[:summary].values.map { |party| party[:related_party].name }).to contain_exactly("Acme Inc.", "Sampaguita Foods Inc.")
    bill = TudlaAccounting::Document.find_by!(organization: organization, contact: TudlaAccounting::Contact.find_by!(name: "Ulap Hosting Inc."))
    expect(bill).to have_attributes(status: "approved", total: Money.new(28_000_00, "PHP"))
    expect(TudlaAccounting::PayRun.due(organization, currency: "PHP")).to include(bill)
  end

  context "with withholding" do
    let(:second_quarter) { TudlaAccounting::FilingQuarters.new(organization).of(Date.current) }
    let(:first_quarter) { TudlaAccounting::FilingQuarters.new(organization).of(Date.new(2026, 3, 1)) }

    def report(first, last) = TudlaAccounting::Reports::Withholding.new(organization, from: first, thru: last)
    def month(number) = TudlaAccounting::Period.leaf_periods_for_date(organization, Time.zone.local(2026, number, 15, 12)).first

    it "has the BIR's starter codes, and the suppliers' 2307s each quarter, with the agent's details" do
      expect(TudlaAccounting::WithholdingCode.where(organization: organization).count).to eq(20)
      expect(TudlaAccounting.configuration.withholding_agent_for(organization)).to include(name: "Demo Pilipinas Inc.", zip: "1226")
      expect(TudlaAccounting::Reports::SupplierCertificates.new(organization, first_quarter).missing_agent_details).to be_empty

      certificates = TudlaAccounting::Reports::SupplierCertificates.new(organization, first_quarter).certificates
      expect(certificates.map { |certificate| [ certificate.contact.name, certificate.lines.map { |line| line.code.code }, certificate.total.cents, certificate.withheld.cents ] })
        .to eq([ [ "Dakila Consulting Corp.", %w[WC050], 60_000_00, 6_000_00 ] ])
      certificates = TudlaAccounting::Reports::SupplierCertificates.new(organization, second_quarter).certificates
      expect(certificates.map { |certificate| [ certificate.contact.name, certificate.withheld.cents ] }).to eq([ [ "Dakila Consulting Corp.", 6_000_00 ], [ "Matibay Builders Inc.", 3_000_00 ] ])
    end

    it "pays a supplier the bill less the tax, posting the tax to the payable" do
      dakila = TudlaAccounting::Contact.find_by!(organization: organization, name: "Dakila Consulting Corp.")
      paid, open = TudlaAccounting::Document.where(organization: organization, contact: dakila).order(:issued_on).with_open_cents.to_a
      expect(paid).to have_attributes(payment_status: "paid", total: Money.new(67_200_00, "PHP"), withheld: Money.new(6_000_00, "PHP"))
      expect(open).to have_attributes(payment_status: "unpaid", amount_due: Money.new(61_200_00, "PHP"))
      checks = report(month(1), this_month).checks("from_supplier")
      expect(checks.map { |check| [ check.account.code, check.listed.cents, check.difference.cents ] }).to eq([ [ "2300", 15_000_00, 0 ] ])
    end

    it "settles Tala's invoices with its payments and the tax, listing only the certified one on the SAWT" do
      tala = TudlaAccounting::Contact.find_by!(organization: organization, name: "Tala Logistics Inc.")
      expect(TudlaAccounting::Document.where(organization: organization, contact: tala).with_open_cents.map(&:payment_status)).to eq(%w[paid paid])
      full = report(month(1), this_month)
      expect(full.sawt.map { |row| [ row.contact.name, row.code.code, row.base.cents, row.withheld.cents ] }).to eq([ [ "Tala Logistics Inc.", "WC160", 100_000_00, 2_000_00 ] ])
      expect(full.waiting.cents).to eq(2_000_00)
      expect(full.checks("by_customer").map { |check| [ check.account.code, check.difference.cents ] }).to eq([ [ "1200", 0 ] ])
    end

    it "has summary lists that tie to the tax summary, with its suppliers' purchases as services" do
      lists = TudlaAccounting::Reports::SummaryLists.new(organization, from: month(1), thru: month(12))
      expect(lists.sales.map { |row| row.contact&.name }).to include("Tala Logistics Inc.")
      expect(lists.purchases.map { |row| row.contact&.name }).to include("Dakila Consulting Corp.")
      expect(lists.total(:purchases)[:not_set]).to eq(Money.new(0, "PHP"))
      %i[sales purchases].each { |side| expect(lists.difference(side)).to have_attributes(base: Money.new(0, "PHP"), tax: Money.new(0, "PHP")) }
    end

    it "splits this month's equipment from the services on the purchases list" do
      rows = TudlaAccounting::Reports::SummaryLists.new(organization, from: month(6), thru: month(6)).purchases
      expect(rows.find { |row| row.contact&.name == "Sulong Equipment Trading Inc." }).to have_attributes(capital_goods: Money.new(80_000_00, "PHP"), services: Money.new(0, "PHP"), tax: Money.new(9_600_00, "PHP"))
      expect(rows.find { |row| row.contact&.name == "Dakila Consulting Corp." }).to have_attributes(services: Money.new(60_000_00, "PHP"), capital_goods: Money.new(0, "PHP"))
    end

    it "has a 2550Q that matches the summary lists, in a filed quarter and the current one" do
      form = TudlaAccounting::TaxReturnForm.find_by!(organization: organization, name: "2550Q")
      [ [ month(1), month(3) ], [ month(4), month(6) ] ].each do |first, last|
        boxes = TudlaAccounting::TaxReturnCalculator.call(form, from: first.from_date, thru: last.thru_date)[:boxes].to_h { |row| [ row.box.label, row.amount ] }
        lists = TudlaAccounting::Reports::SummaryLists.new(organization, from: first, thru: last)
        sales = lists.total(:sales)
        purchases = lists.total(:purchases)
        expect(boxes.values_at("31A", "31B", "32A", "33A")).to eq(sales.values_at(:taxable, :tax, :zero_rated, :exempt))
        expect(boxes["44A"]).to eq(purchases.values_at(:services, :capital_goods, :other_goods, :not_set).sum)
        expect(boxes["44B"]).to eq(purchases[:tax])
      end
    end

    it "makes each supplier's 2307 on one sheet" do
      quarter = TudlaAccounting::Reports::SupplierCertificates.new(organization, second_quarter)
      pages = PDF::Reader.new(StringIO.new(TudlaAccounting::PdfMaker.supplier_certificates(quarter, quarter.certificates))).pages
      expect(pages.size).to eq(2)
      expect(pages.first.text).to include("Dakila Consulting Corp.", "1100", "1 Ayala Avenue, Makati City", "WC050", "Maria Santos")
    end
  end
end
