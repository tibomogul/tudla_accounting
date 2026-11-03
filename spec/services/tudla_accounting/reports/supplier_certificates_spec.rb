require "rails_helper"
require_relative "../../../support/configuration"

RSpec.describe TudlaAccounting::Reports::SupplierCertificates, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }
  let(:fees) { code("WC010", "0.10") }
  let(:contractors) { code("WC120", "0.02") }
  let(:ledger) { TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier", tax_number: "123-456-789-000") }
  let(:aurora) { TudlaAccounting::Contact.create!(organization: organization, name: "aurora Builders", kind: "supplier") }
  let(:first_quarter) { TudlaAccounting::FilingQuarters.new(organization).of(Date.new(2026, 2, 1)) }
  let(:second_quarter) { TudlaAccounting::FilingQuarters.new(organization).of(Date.new(2026, 5, 1)) }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2300", name: "Withholding payable", category: "liability" }, { code: "6000", name: "Fees", category: "expense" }
    ], organization)
  end

  def account(number) = TudlaAccounting::Account.find_by!(organization: organization, code: number)
  def code(number, rate) = TudlaAccounting::WithholdingCode.create!(organization: organization, code: number, name: "Code #{number}", rate: rate, payable_account: account("2300"))

  def bill(contact, withholding, on, cents, kind: "bill")
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: contact, issued_on: on, lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account("6000"), withholding_code: withholding } ]).approve!
  end

  def report(quarter = first_quarter) = described_class.new(organization, quarter)
  def amounts(values) = values.map(&:cents)

  it "gives each supplier's income by code and month, and the quarter's tax, by supplier name" do
    bill(ledger, fees, Date.new(2026, 1, 10), 100_000_00)
    bill(ledger, fees, Date.new(2026, 1, 20), 20_000_00)
    bill(ledger, fees, Date.new(2026, 3, 5), 50_000_00)
    bill(ledger, contractors, Date.new(2026, 2, 5), 10_000_00)
    bill(aurora, contractors, Date.new(2026, 2, 6), 5_000_00)
    bill(aurora, contractors, Date.new(2026, 4, 1), 7_000_00)

    expect(report.months).to eq([ Date.new(2026, 1, 1), Date.new(2026, 2, 1), Date.new(2026, 3, 1) ])
    expect(report.certificates.map { |certificate| certificate.contact.name }).to eq([ "aurora Builders", "Ledger & Co" ])

    certificate = report.certificates.last
    expect(certificate.lines.map { |line| line.code.code }).to eq(%w[WC010 WC120])
    expect(amounts(certificate.lines.first.months)).to eq([ 120_000_00, 0, 50_000_00 ])
    expect(certificate.lines.first.total.cents).to eq(170_000_00)
    expect(certificate.lines.first.withheld.cents).to eq(17_000_00)
    expect(certificate.total.cents).to eq(180_000_00)
    expect(certificate.withheld.cents).to eq(17_200_00)
    expect(certificate).not_to be_negative
    expect(report(second_quarter).certificates.sole.total.cents).to eq(7_000_00)
  end

  it "counts a void and a supplier credit in the month dated, leaving out what nets to nothing, and leaves tax withheld by customers out" do
    voided = bill(ledger, fees, Date.new(2026, 1, 10), 100_000_00)
    bill(aurora, contractors, Date.new(2026, 3, 10), 10_000_00)
    bill(aurora, contractors, Date.new(2026, 3, 20), 4_000_00, kind: "supplier_credit")
    voided.void!(on: Date.new(2026, 4, 2), reason: "Entered twice")

    expect(report.certificates.map { |certificate| certificate.contact.name }).to eq([ "aurora Builders", "Ledger & Co" ])
    expect(report.certificates.first.total.cents).to eq(6_000_00)
    later = report(second_quarter).certificates.sole
    expect(later.total.cents).to eq(-100_000_00)
    expect(later).to be_negative

    bill(aurora, contractors, Date.new(2026, 5, 1), 4_000_00)
    bill(aurora, contractors, Date.new(2026, 5, 2), 4_000_00, kind: "supplier_credit")
    expect(report(second_quarter).certificates.map { |certificate| certificate.contact.name }).to eq([ "Ledger & Co" ])

    customer = TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer")
    TudlaAccounting::AccountsCreator.call([ { code: "1010", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "1200", name: "Creditable tax", category: "asset" } ], organization)
    from_customer = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC160", name: "Services", rate: "0.02", creditable_account: account("1200"))
    TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: customer, account: account("1010"), paid_on: Date.new(2026, 5, 3), amount_cents: 9_800_00, withholdings: [ { code: from_customer, withheld_cents: 200_00 } ])
    expect(report(second_quarter).certificates.map { |certificate| certificate.contact.name }).to eq([ "Ledger & Co" ])
  end

  it "takes a sheet for every ten lines, each with its own totals" do
    12.times { |index| bill(ledger, code("WX%03d" % index, "0.02"), Date.new(2026, 2, 1), 1_000_00) }

    sheets = report.certificates.sole.sheets
    expect(sheets.map { |sheet| sheet.lines.size }).to eq([ 10, 2 ])
    expect(sheets.map { |sheet| sheet.total.cents }).to eq([ 10_000_00, 2_000_00 ])
    expect(sheets.map { |sheet| sheet.withheld.cents }).to eq([ 200_00, 40_00 ])
    expect(sheets.first.month_total(1).cents).to eq(10_000_00)
    expect(sheets.first.month_total(0).cents).to eq(0)
  end

  it "says who has no TIN, and what the withholding_agent setting hasn't given" do
    bill(ledger, fees, Date.new(2026, 1, 10), 1_000_00)
    bill(aurora, fees, Date.new(2026, 1, 10), 1_000_00)
    expect(report.waiting_for_tin.map { |certificate| certificate.contact.name }).to eq([ "aurora Builders" ])
    expect(report.missing_agent_details).to eq([ "TIN", "address", "ZIP code", "signatory's name", "signatory's title", "signatory's TIN" ])

    TudlaAccounting.configuration.withholding_agent = ->(org) { { tin: "1", name: "#{org.name} (registered)", address: "1 Demo Street", zip: "1223", signatory_name: "A", signatory_title: "B", signatory_tin: "2" } }
    expect(report.missing_agent_details).to be_empty
    expect(TudlaAccounting.configuration.withholding_agent_for(organization)).to include(name: "Bayanihan Corp. (registered)", zip: "1223")
  end

  it "fills the form's TIN boxes, or leaves a number that doesn't fit them to be written out" do
    boxes = ->(*digits) { digits.map { |group| group.chars } }
    expect(described_class.tin_boxes("123-456-789-000")).to eq(boxes.call("123", "456", "789", "000  "))
    expect(described_class.tin_boxes("123 456 789 00000")).to eq(boxes.call("123", "456", "789", "00000"))
    expect(described_class.tin_boxes("123456789")).to eq(boxes.call("123", "456", "789", "     "))
    expect(described_class.tin_boxes(nil)).to eq(boxes.call("   ", "   ", "   ", "     "))
    expect(described_class.tin_boxes("FOREIGN-99")).to be_nil
    expect(described_class.tin_boxes("1" * 15)).to be_nil
  end
end
