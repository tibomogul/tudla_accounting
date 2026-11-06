require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Payments with tax withheld, by payee", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:noabn) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "NOABN", name: "No ABN quoted", rate: "0.47", payable_account: account("2350"), withheld_on: "payment") }
  let(:handy) { TudlaAccounting::Contact.create!(organization: organization, name: "Handy Repairs", kind: "supplier", address: "1 Main St\nSpringfield", postal_code: "2000") }
  let(:odd_jobs) { TudlaAccounting::Contact.create!(organization: organization, name: "Odd Jobs", kind: "supplier") }

  before do
    travel_to Time.zone.local(2026, 5, 25, 9)
    sign_in_as(organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def text(selector) = css_select(selector).map { |node| node.text.squish }
  def cells(selector) = css_select(selector).map { |row| row.css("td").map { |cell| cell.text.squish }.join(" | ") }
  def month(year, number) = TudlaAccounting::Period.leaf_periods_for_date(organization, Time.zone.local(year, number, 15, 12)).first

  def pay(supplier, on, base_cents)
    TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: supplier, account: account("1010"), paid_on: on,
                                     amount_cents: base_cents - noabn.withheld_cents(base_cents), withholdings: [ { code: noabn, base_cents: base_cents } ])
  end

  it "says so without periods" do
    get routes.reports_payee_payments_path
    expect(response.body).to include("to see reports.")
    get routes.reports_payee_payments_path(format: :csv)
    expect(response).to have_http_status(:not_found)
  end

  context "with financial years" do
    before do
      TudlaAccounting::PeriodCreator.call(organization, 2025)
      TudlaAccounting::PeriodCreator.call(organization, 2026)
      TudlaAccounting::AccountsCreator.call([
        { code: "1010", name: "Bank", category: "asset" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
        { code: "2350", name: "No-ABN withholding", category: "liability" }, { code: "6000", name: "Repairs", category: "expense" }
      ], organization)
    end

    it "asks for a code withheld on payment, and is offered once there is one" do
      TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Contractors", rate: "0.02", payable_account: account("2350"))
      get routes.reports_path
      expect(text("a .font-semibold")).not_to include("Payments with tax withheld, by payee")
      get routes.reports_payee_payments_path
      expect(response.body).to include("No withholding codes are withheld when a supplier is paid.")
      noabn
      get routes.reports_path
      expect(text("a .font-semibold")).to include("Payments with tax withheld, by payee")
    end

    it "lists each payee's gross payments and tax for the last financial year, leaving out other codes and what nets to nothing" do
      pay(handy, Date.new(2025, 8, 2), 1_000_00)
      pay(handy, Date.new(2025, 11, 3), 500_00)
      pay(odd_jobs, Date.new(2025, 9, 9), 200_00)
      pay(handy, Date.new(2026, 2, 1), 300_00) # this year
      voided = pay(TudlaAccounting::Contact.create!(organization: organization, name: "Gone Co", kind: "supplier"), Date.new(2025, 6, 1), 100_00)
      voided.void!(on: Date.new(2025, 6, 2), reason: "Wrong supplier")
      wc120 = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Contractors", rate: "0.02", payable_account: account("2350"))
      TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: handy, issued_on: Date.new(2025, 4, 10),
                                        lines_attributes: [ { description: "Work", unit_price_cents: 100_00, account: account("6000"), withholding_code: wc120 } ]).approve!

      get routes.reports_payee_payments_path
      expect(response.body).to include("1 Jan 2025 to 31 Dec 2025")
      expect(cells("tr[data-payee-row]")).to eq([ "Handy Repairs | 1 Main St Springfield 2000 | NOABN | 1,500.00 | 705.00 | Payment summary", "Odd Jobs | No address | NOABN | 200.00 | 94.00 | Payment summary" ])
      expect(text("[data-total]")).to eq([ "1,700.00", "799.00" ])
      expect(text("[data-missing-address]")).to eq([ "No address for Odd Jobs. Add it on the contact before reporting." ])
      expect(cells("[data-withholding-check] tbody tr")).to eq([ "2350 - No-ABN withholding | 799.00 | 801.00 | 2.00" ])

      get routes.reports_payee_payments_path(from_id: month(2026, 1).id, thru_id: month(2026, 6).id)
      expect(cells("tr[data-payee-row]")).to eq([ "Handy Repairs | 1 Main St Springfield 2000 | NOABN | 300.00 | 141.00 | Payment summary" ])

      get routes.reports_payee_payments_path(format: :csv)
      expect(response.headers["Content-Disposition"]).to include("payee-payments-2025-01-01-to-2025-12-31.csv")
      csv = CSV.parse(response.body)
      expect(csv.first).to eq([ "No.", "Payee", "Address", "Postal code", "Code", "Gross payment", "Tax withheld", "Note" ])
      expect(csv[2]).to eq([ "2", "Odd Jobs", nil, nil, "NOABN", "200.00", "94.00", "No address" ])
      expect(csv.last).to eq([ nil, "Total", nil, nil, nil, "1700.00", "799.00", nil ])
    end

    it "makes each payee's payment summary, or all of them, as a PDF listing its payments" do
      TudlaAccounting.configuration.tax_registration = ->(_org) { TudlaAccounting::TaxRegistration.australia("51 824 753 556") }
      first = pay(handy, Date.new(2025, 8, 2), 1_000_00)
      first.update_column(:reference, "EFT 1001")
      pay(handy, Date.new(2025, 11, 3), 500_00).void!(on: Date.new(2025, 11, 4), reason: "Paid twice")
      pay(odd_jobs, Date.new(2025, 9, 9), 200_00)

      get routes.reports_payee_payments_path
      expect(css_select("a[aria-label='Payment summary for Handy Repairs']").first["href"]).to include(".pdf", "contact_id=#{handy.id}")
      expect(text("a.tc-btn")).to include("All payment summaries")

      get routes.reports_payee_payments_path(format: :pdf, contact_id: handy.id)
      expect(response.headers["Content-Disposition"]).to include("payment-summary-Handy-Repairs-2025-01-01-to-2025-12-31.pdf")
      pdf = PDF::Reader.new(StringIO.new(response.body))
      expect(pdf.pages.size).to eq(1)
      words = pdf.pages.map(&:text).join("\n").squish
      expect(words).to include("Payment summary", "Acme", "ABN 51 824 753 556", "1 Jan 2025 to 31 Dec 2025", "Handy Repairs", "1 Main St", "No ABN quoted (47%)",
                               "1,000.00", "470.00", "EFT 1001", "Payment voided", "(500.00)", "(235.00)", "Signed for the payer")
      expect(words).not_to include("Odd Jobs")

      get routes.reports_payee_payments_path(format: :pdf)
      expect(response.headers["Content-Disposition"]).to include("payment-summary-all-payees-2025-01-01-to-2025-12-31.pdf")
      expect(PDF::Reader.new(StringIO.new(response.body)).pages.size).to eq(2)

      get routes.reports_payee_payments_path(format: :pdf, contact_id: 0)
      expect(response).to have_http_status(:not_found)
    end

    it "shows nothing withheld, and the year to date when no earlier year has ended" do
      noabn
      TudlaAccounting::Period.where(organization: organization).roots.where(from_date: ...Date.new(2026, 1, 1)).first.then do |year|
        TudlaAccounting::Period.where(organization: organization).where("ancestry LIKE ?", "%/#{year.id}/%").or(TudlaAccounting::Period.where(id: year.id)).delete_all
      end
      get routes.reports_payee_payments_path
      expect(response.body).to include("1 Jan 2026 to 31 May 2026", "Nothing withheld in these months.")
    end
  end
end
