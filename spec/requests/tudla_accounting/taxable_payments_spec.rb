require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Taxable payments, by payee", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GSTP", name: "GST on purchases", rate: "0.1", kind: :purchases, account: account("1300")) }
  let(:noabn) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "NOABN", name: "No ABN quoted", rate: "0.47", payable_account: account("2350"), withheld_on: "payment") }
  let(:builder) { contractor("Bricks & Co", tax_number: "51 824 753 556", address: "1 Main St", postal_code: "2000") }
  let(:cleaner) { contractor("Sparkle Cleaning") }

  before do
    travel_to Time.zone.local(2026, 5, 25, 9)
    sign_in_as(organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def text(selector) = css_select(selector).map { |node| node.text.squish }
  def cells(selector) = css_select(selector).map { |row| row.css("td").map { |cell| cell.text.squish }.join(" | ") }
  def month(year, number) = TudlaAccounting::Period.leaf_periods_for_date(organization, Time.zone.local(year, number, 15, 12)).first
  def contractor(name, **attributes) = TudlaAccounting::Contact.create!(organization: organization, name: name, kind: "supplier", taxable_payments: true, **attributes)

  def bill(supplier, on, cents, tax_code: gst)
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: on,
                                      lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account("6000"), tax_code: tax_code } ]).approve!
  end

  def pay(supplier, on, cash, applications: [], withholdings: [])
    TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: supplier, account: account("1010"), paid_on: on, amount_cents: cash,
                                     applications: applications, withholdings: withholdings)
  end

  it "says so without periods" do
    get routes.reports_taxable_payments_path
    expect(response.body).to include("to see reports.")
  end

  context "with financial years" do
    before do
      TudlaAccounting::PeriodCreator.call(organization, 2025)
      TudlaAccounting::PeriodCreator.call(organization, 2026)
      TudlaAccounting::AccountsCreator.call([
        { code: "1010", name: "Bank", category: "asset" }, { code: "1300", name: "GST paid", category: "asset" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
        { code: "2350", name: "No-ABN withholding", category: "liability" }, { code: "6000", name: "Contractors", category: "expense" }
      ], organization)
    end

    it "asks for contacts to be marked, and is offered once one is" do
      get routes.reports_path
      expect(text("a .font-semibold")).not_to include("Taxable payments, by payee")
      get routes.reports_taxable_payments_path
      expect(response.body).to include("No contacts are marked for taxable payments yet.")
      builder
      get routes.reports_path
      expect(text("a .font-semibold")).to include("Taxable payments, by payee")
    end

    it "lists what was paid to each marked contact in the last financial year, with the GST in it and any tax withheld" do
      whole = bill(builder, Date.new(2025, 3, 1), 1_000_00) # 1,100 with GST
      pay(builder, Date.new(2025, 3, 10), 1_100_00, applications: [ { document: whole, amount_cents: 1_100_00 } ])
      half = bill(builder, Date.new(2025, 6, 1), 2_000_00) # 2,200 with GST, half paid
      pay(builder, Date.new(2025, 6, 10), 1_100_00, applications: [ { document: half, amount_cents: 1_100_00 } ])
      later = pay(builder, Date.new(2025, 12, 1), 550_00, applications: [ { document: half, amount_cents: 550_00 } ])
      later.void!(on: Date.new(2026, 1, 5), reason: "Bounced") # voided this year: last year keeps it
      pay(cleaner, Date.new(2025, 8, 1), 200_00) # an advance on no bill
      cleaner.update!(default_withholding_code: noabn)
      untaxed = bill(cleaner, Date.new(2025, 9, 1), 1_000_00, tax_code: nil)
      pay(cleaner, Date.new(2025, 9, 5), 530_00, applications: [ { document: untaxed, amount_cents: 1_000_00 } ], withholdings: [ { code: noabn, base_cents: 1_000_00 } ])
      shop = TudlaAccounting::Contact.create!(organization: organization, name: "Paper Shop", kind: "supplier")
      pay(shop, Date.new(2025, 4, 1), 99_00) # not marked

      get routes.reports_taxable_payments_path
      expect(response.body).to include("1 Jan 2025 to 31 Dec 2025")
      expect(cells("tr[data-payee-row]")).to eq([ "51 824 753 556 | Bricks & Co | 1 Main St 2000 | 3 | 2,750.00 | 250.00 | 0.00",
                                                  "No ABN | Sparkle Cleaning | No address | 2 | 1,200.00 | 0.00 | 470.00" ])
      expect(text("[data-total]")).to eq([ "3,950.00", "250.00", "470.00" ])
      expect(text("[data-missing]")).to eq([ "No ABN for Sparkle Cleaning. Add it on the contact before reporting.", "No address for Sparkle Cleaning. Add it on the contact before reporting." ])
      expect(text("[data-unapplied]").sole).to start_with("Some of what was paid to Sparkle Cleaning wasn't applied to a bill")

      get routes.reports_taxable_payments_path(from_id: month(2026, 1).id, thru_id: month(2026, 6).id)
      expect(cells("tr[data-payee-row]")).to eq([ "51 824 753 556 | Bricks & Co | 1 Main St 2000 | -1 | (550.00) | (50.00) | 0.00" ])

      get routes.reports_taxable_payments_path(format: :csv)
      csv = CSV.parse(response.body)
      expect(csv.first).to eq([ "No.", "ABN", "Payee", "Address", "Postal code", "Phone", "Gross paid", "GST", "Tax withheld", "Note" ])
      expect(csv[2]).to eq([ "2", nil, "Sparkle Cleaning", nil, nil, nil, "1200.00", "0.00", "470.00", "No ABN; No address; 200.00 paid on no bill, so no GST" ])
      expect(csv.last).to eq([ nil, nil, "Total", nil, nil, nil, "3950.00", "250.00", "470.00", nil ])
    end

    it "takes off a refund from the supplier with its credit's GST, and converts a foreign bill's GST at the bill's rate" do
      TudlaAccounting::AccountsCreator.call([ { code: "1020", name: "Dollar account", category: "asset", currency: "USD" },
                                              { code: "7900", name: "Exchange gains", category: "income", role: "realized_fx_gain" } ], organization)
      paid = bill(builder, Date.new(2025, 3, 1), 1_000_00)
      pay(builder, Date.new(2025, 3, 10), 1_100_00, applications: [ { document: paid, amount_cents: 1_100_00 } ])
      credit = TudlaAccounting::Document.create!(organization: organization, kind: "supplier_credit", contact: builder, issued_on: Date.new(2025, 4, 1),
                                                 lines_attributes: [ { description: "Overcharge", unit_price_cents: 100_00, account: account("6000"), tax_code: gst } ]).approve!
      refund = TudlaAccounting::Payment.record!(organization: organization, kind: "supplier_refund", contact: builder, account: account("1010"), paid_on: Date.new(2025, 4, 5),
                                                amount_cents: 110_00, refund_of: credit)
      dollars = TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: cleaner, issued_on: Date.new(2025, 5, 1), currency: "USD", exchange_rate: "1.5",
                                                  lines_attributes: [ { description: "Work", unit_price_cents: 100_00, account: account("6000"), tax_code: gst } ]).approve!
      TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: cleaner, account: account("1020"), paid_on: Date.new(2025, 5, 10), amount_cents: 110_00,
                                       exchange_rate: "1.6", applications: [ { document: dollars, amount_cents: 110_00 } ])

      get routes.reports_taxable_payments_path
      expect(cells("tr[data-payee-row]")).to eq([ "51 824 753 556 | Bricks & Co | 1 Main St 2000 | 1 | 990.00 | 90.00 | 0.00",
                                                  "No ABN | Sparkle Cleaning | No address | 1 | 176.00 | 15.00 | 0.00" ])

      refund.void!(on: Date.new(2026, 2, 1), reason: "Bounced") # voided this year: it counts back this year
      get routes.reports_taxable_payments_path(from_id: month(2026, 1).id, thru_id: month(2026, 6).id)
      expect(cells("tr[data-payee-row]")).to eq([ "51 824 753 556 | Bricks & Co | 1 Main St 2000 | 0 | 110.00 | 10.00 | 0.00" ])
    end

    it "takes no more queries for more payments" do
      count = lambda do
        queries = 0
        counter = ->(*, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get routes.reports_taxable_payments_path }
        queries
      end
      paid = bill(builder, Date.new(2025, 3, 1), 1_000_00)
      pay(builder, Date.new(2025, 3, 10), 1_100_00, applications: [ { document: paid, amount_cents: 1_100_00 } ])
      few = count.call
      3.times do |index|
        supplier = contractor("Contractor #{index}")
        paid = bill(supplier, Date.new(2025, 4, 1), 1_000_00)
        pay(supplier, Date.new(2025, 4, 10), 600_00, applications: [ { document: paid, amount_cents: 600_00 } ])
        pay(supplier, Date.new(2025, 4, 11), 500_00, applications: [ { document: paid, amount_cents: 500_00 } ])
      end
      expect(count.call).to be <= few
    end

    it "counts a payment moved to another bill once, and shows nothing paid in an empty year" do
      first = bill(builder, Date.new(2025, 3, 1), 1_000_00)
      second = bill(builder, Date.new(2025, 3, 2), 1_000_00)
      payment = pay(builder, Date.new(2025, 3, 10), 1_100_00, applications: [ { document: first, amount_cents: 1_100_00 } ])
      TudlaAccounting::Allocator.unallocate!(payment.applications.sole.last)
      TudlaAccounting::Allocator.allocate!(payment.entry, second.entry, amount_cents: 1_100_00)
      get routes.reports_taxable_payments_path
      expect(cells("tr[data-payee-row]")).to eq([ "51 824 753 556 | Bricks & Co | 1 Main St 2000 | 1 | 1,100.00 | 100.00 | 0.00" ])

      get routes.reports_taxable_payments_path(from_id: month(2026, 1).id, thru_id: month(2026, 3).id)
      expect(response.body).to include("Nothing paid to them in these months.")
    end
  end
end
