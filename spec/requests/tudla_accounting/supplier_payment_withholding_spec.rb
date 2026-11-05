require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Tax withheld when paying a supplier", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:noabn) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "NOABN", name: "No ABN quoted", rate: "0.47", payable_account: account("2350"), withheld_on: "payment") }
  let(:supplier) { TudlaAccounting::Contact.create!(organization: organization, name: "Handy Repairs", kind: "supplier", default_withholding_code: noabn) }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "1200", name: "Creditable tax", category: "asset" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2350", name: "No-ABN withholding", category: "liability" }, { code: "6000", name: "Repairs", category: "expense" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def text(selector) = css_select(selector).map { |node| node.text.squish }
  def field(name) = css_select("[name='#{name}']").first

  def bill
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 4, 1),
                                      lines_attributes: [ { description: "Repairs", unit_price_cents: 1_000_00, account: account("6000") } ]).approve!
  end

  it "asks for it only once there's a code withheld on payment, and not on payments received" do
    plain = TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier")
    get routes.new_payment_path(kind: "paid", contact_id: plain.id)
    expect(response.body).not_to include("data-withholdings")
    get routes.new_payment_path(kind: "paid", contact_id: supplier.id)
    expect(text("[data-withholdings] h2")).to eq([ "Tax withheld from Handy Repairs" ])
    expect(css_select("[data-withholdings] select option").map(&:text)).to eq([ "Choose a code", "NOABN (47%) No ABN quoted" ])
    expect(text("label[for=payment_amount]")).to eq([ "Cash paid (AUD)" ])
    customer = TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer")
    get routes.new_payment_path(kind: "received", contact_id: customer.id)
    expect(response.body).not_to include("data-withholdings")
  end

  it "starts paying a bill with the tax on what's owed, records it from the amount alone, and shows it on the payment and notice" do
    owed = bill
    get routes.new_payment_path(document_id: owed.id)
    expect(field("payment[withholdings][0][withholding_code_id]").css("option[selected]").map(&:text)).to eq([ "NOABN (47%) No ABN quoted" ])
    expect([ field("payment[withholdings][0][base]")["value"], field("payment[withholdings][0][withheld]")["value"], field("payment[amount]")["value"] ]).to eq(%w[1000.00 470.00 530.00])

    post routes.payments_path, params: { payment: { kind: "paid", contact_id: supplier.id, account_id: account("1010").id, paid_on: "2026-04-15", amount: "530.00",
                                                    applications: { owed.id.to_s => "1000.00" }, withholdings: { "0" => { withholding_code_id: noabn.id, withheld: "", base: "1000.00" } } } }
    payment = TudlaAccounting::Payment.find_by!(organization: organization)
    expect(response).to redirect_to(routes.payment_path(payment))
    expect(payment).to have_attributes(amount_cents: 530_00, withheld_cents: 470_00)
    expect(owed.reload.payment_status).to eq("paid")
    expect(TudlaAccounting::WithheldTax.where(organization: organization).sole).to have_attributes(direction: "from_supplier", base_cents: 1_000_00, withheld_cents: 470_00)

    get routes.payment_path(payment)
    expect(text("[data-withheld-taxes] th")).to eq([ "Code", "Withheld from", "Tax withheld" ])
    expect(text("[data-withheld-taxes] tbody td")).to eq([ "NOABN (47%)", "1,000.00", "470.00" ])
    expect(text("[data-document] tfoot tr")).to eq([ "Total settled1,000.00", "Less tax we withheld, NOABN(470.00)", "Total paid530.00" ])
  end

  it "leaves the tax out when the supplier has quoted an ABN, and keeps what was typed when it can't record" do
    owed = bill
    post routes.payments_path, params: { payment: { kind: "paid", contact_id: supplier.id, account_id: account("1010").id, paid_on: "2026-04-15", amount: "1000.00",
                                                    applications: { owed.id.to_s => "1000.00" }, withholdings: { "0" => { withholding_code_id: noabn.id, withheld: "", base: "" } } } }
    expect(TudlaAccounting::Payment.find_by!(organization: organization).withheld_cents).to eq(0)

    post routes.payments_path, params: { payment: { kind: "paid", contact_id: supplier.id, account_id: account("1010").id, paid_on: "2026-04-15", amount: "530.00",
                                                    withholdings: { "0" => { withholding_code_id: "", withheld: "", base: "1000.00" } } } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(CGI.unescapeHTML(response.body)).to include("Choose a withholding code for the tax withheld")
    expect(field("payment[withholdings][0][base]")["value"]).to eq("1000.00")
  end

  it "starts a bill with no tax when the supplier's default isn't withheld on payment" do
    supplier.update!(default_withholding_code: nil)
    get routes.new_payment_path(document_id: bill.id)
    expect(field("payment[withholdings][0][base]")["value"]).to be_nil
    expect(field("payment[amount]")["value"]).to eq("1000.00")
  end
end
