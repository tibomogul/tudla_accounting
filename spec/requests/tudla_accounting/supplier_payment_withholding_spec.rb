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
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 4, 1), due_on: Date.new(2026, 4, 30),
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

  it "withholds it in a pay run, from what is paid of the supplier's bills" do
    owed = bill
    plain = TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier")
    other = TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: plain, issued_on: Date.new(2026, 4, 1), due_on: Date.new(2026, 4, 30),
                                              lines_attributes: [ { description: "Books", unit_price_cents: 200_00, account: account("6000") } ]).approve!
    get routes.new_pay_run_path(account_id: account("1010").id, due_by: "2026-05-31")
    expect(text("tbody[data-supplier] [data-withholding]")).to eq([ "· withhold NOABN (47%) from what is paid" ])
    expect(css_select("input[type=checkbox][name='pay_run[withhold][#{supplier.id}]']").sole["checked"]).to eq("checked")

    post routes.pay_run_path, params: { pay_run: { account_id: account("1010").id, due_by: "2026-05-31", paid_on: "2026-04-15", reference: "Pay run",
                                                   pay: { owed.id.to_s => "1", other.id.to_s => "1" }, amounts: { owed.id.to_s => "1000.00", other.id.to_s => "200.00" } } }
    expect(flash[:notice]).to eq("Paid 2 suppliers $730.00 in all, after withholding $470.00 in tax.")
    paid = TudlaAccounting::Payment.where(organization: organization).to_h { |payment| [ payment.contact.name, [ payment.amount_cents, payment.withheld_cents ] ] }
    expect(paid).to eq("Handy Repairs" => [ 530_00, 470_00 ], "Ledger & Co" => [ 200_00, 0 ])
    expect([ owed, other ].map { |document| document.reload.payment_status }).to eq(%w[paid paid])
    expect(TudlaAccounting::WithheldTax.where(organization: organization).sole).to have_attributes(contact: supplier, base_cents: 1_000_00, withheld_cents: 470_00)
  end

  it "pays a supplier in full in a pay run when told not to withhold this time, keeping the choice when it can't pay" do
    owed = bill
    run = { account_id: account("1010").id, due_by: "2026-05-31", reference: "Pay run", pay: { owed.id.to_s => "1" }, amounts: { owed.id.to_s => "1000.00" },
            withhold: { supplier.id.to_s => "0" } }
    post routes.pay_run_path, params: { pay_run: run.merge(paid_on: "") }
    expect(css_select("input[type=checkbox][name='pay_run[withhold][#{supplier.id}]']").sole["checked"]).to be_nil

    post routes.pay_run_path, params: { pay_run: run.merge(paid_on: "2026-04-15") }
    expect(flash[:notice]).to eq("Paid 1 supplier $1,000.00 in all.")
    expect(TudlaAccounting::Payment.where(organization: organization).sole).to have_attributes(amount_cents: 1_000_00, withheld_cents: 0)
    expect(TudlaAccounting::WithheldTax.where(organization: organization)).to be_empty
  end

  it "withholds it when a bank line is recorded as paying the bill, the line being the cash after the tax" do
    owed = bill
    lines = [ -530_00, -300_00 ].each_with_index.map do |cents, index|
      TudlaAccounting::BankStatementLine.create!(organization: organization, account: account("1010"), occurred_on: Date.new(2026, 4, 12), description: "HANDY REPAIRS",
                                                 amount_cents: cents, currency: "AUD", external_id: index.to_s)
    end
    get routes.banking_account_path(account("1010"))
    expect(text("select#document_id_#{lines.first.id} option")).to eq([ "BILL-0001 Handy Repairs ($1,000.00 owed, $530.00 after NOABN)" ])

    post routes.record_payment_bank_statement_line_path(lines.last), params: { document_id: owed.id }
    expect(TudlaAccounting::Payment.last).to have_attributes(amount_cents: 300_00, withheld_cents: 266_04)
    expect(owed.reload.amount_due.cents).to eq(1_000_00 - 566_04)
    expect(TudlaAccounting::WithheldTax.where(organization: organization).sole).to have_attributes(base_cents: 566_04, withheld_cents: 266_04)
  end
end
