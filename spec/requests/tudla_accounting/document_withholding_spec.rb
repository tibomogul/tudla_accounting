require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Withholding on bills", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }
  let(:code) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Contractors", rate: "0.02", payable_account: account("2300")) }
  let(:supplier) { TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier", default_withholding_code: code, default_account: account("6000")) }

  before do
    travel_to Time.zone.local(2026, 3, 25, 9)
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "2300", name: "Withholding payable", category: "liability" }, { code: "4000", name: "Sales", category: "income" }, { code: "6000", name: "Repairs", category: "expense" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def text(selector) = css_select(selector).map { |node| node.text.squish }

  def approved_bill(cents: 10_000_00)
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 3, 10),
                                      lines_attributes: [ { description: "Aircon repair", unit_price_cents: cents, account: account("6000"), withholding_code: code } ]).approve!
  end

  it "offers no withholding on a bill without codes for it, or on an invoice" do
    get routes.new_document_path(kind: "bill")
    expect(response.body).not_to include("withholding_code_id", "Amount payable")
    code
    get routes.new_document_path(kind: "sales_invoice")
    expect(response.body).not_to include("withholding_code_id", "Amount payable")
  end

  it "starts a supplier's bill with their default, saves another, and approves it" do
    get routes.new_document_path(kind: "bill", contact_id: supplier.id)
    expect(css_select("select[name='document[lines][0][withholding_code_id]'] option[selected]").map(&:text)).to eq([ "WC120 (2%)" ])
    expect(css_select("select[name='document[contact_id]'] option").last["data-withholding"]).to eq(code.id.to_s)
    expect(response.body).to include("Less tax withheld", "Amount payable")

    other = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC100", name: "Rent", rate: "0.05", payable_account: account("2300"))
    post routes.documents_path, params: { approve: "1", document: { kind: "bill", contact_id: supplier.id, issued_on: "2026-03-10", lines: { "0" => { description: "Rent", quantity: "1", unit_price: "1,000", account_id: account("6000").id, withholding_code_id: other.id } } } }
    bill = TudlaAccounting::Document.last
    expect(bill).to have_attributes(status: "approved", withheld_cents: 50_00, payable_cents: 950_00)

    follow_redirect!
    expect(text("[data-withheld]")).to eq([ "Less tax withheld, WC100 (5%)(50.00)" ])
    expect(text("[data-document] tfoot tr")).to include("Total1,000.00", "Amount payable950.00")
    expect(text("[data-document] tfoot tr")).not_to include(a_string_starting_with("Paid or credited"))
  end

  it "clears a code left blank, and copies the codes to a supplier credit" do
    bill = approved_bill
    get routes.new_document_path(credit: bill.id)
    expect(css_select("select[name='document[lines][0][withholding_code_id]'] option[selected]").map(&:text)).to eq([ "WC120 (2%)" ])

    post routes.documents_path, params: { document: { kind: "bill", contact_id: supplier.id, issued_on: "2026-03-10", lines: { "0" => { description: "Parts", quantity: "1", unit_price: "100", account_id: account("6000").id, withholding_code_id: "" } } } }
    expect(TudlaAccounting::Document.last.lines.sole.withholding_code).to be_nil
  end

  it "treats a bill as unpaid or part paid against what is owed, and lists what was withheld" do
    bill = approved_bill
    get routes.purchase_documents_path(status: "unpaid")
    expect(response.body).to include(bill.number_label)
    get routes.purchase_documents_path(status: "part_paid")
    expect(response.body).not_to include(bill.number_label)

    TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: supplier, account: account("1010"), paid_on: Date.new(2026, 3, 20), amount_cents: 4_000_00, applications: [ { document: bill, amount_cents: 4_000_00 } ])
    get routes.purchase_documents_path(status: "part_paid")
    expect(response.body).to include(bill.number_label)
    get routes.purchase_documents_path(status: "unpaid")
    expect(response.body).not_to include(bill.number_label)

    get routes.document_path(bill)
    expect(text("[data-document] tfoot tr")).to include("Amount payable9,800.00", "Paid or credited(4,000.00)", "Amount due5,800.00")

    get routes.purchase_documents_path(format: :csv)
    table = CSV.parse(response.body)
    expect(table.first.last).to eq("Tax withheld")
    expect(table.last.last).to eq("200.00")

    get routes.payment_path(TudlaAccounting::Payment.last)
    expect(text("[data-withheld]")).to eq([ "200.00 tax withheld from the bill" ])
  end

  it "prints what was withheld on the PDF" do
    get routes.document_path(approved_bill, format: :pdf)
    pdf = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n").squish
    expect(pdf).to include("Less tax withheld, WC120 (2%)", "Amount payable", "9,800.00")
  end
end
