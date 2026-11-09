require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

# Payments to a supplier whose code is withheld on payment (no-ABN withholding) that aren't
# withheld from: a supply under the code's limit, an exempt supplier, or a reason given, each
# kept on the payment and listed for checking at year end.
RSpec.describe "Payments made without withholding, and why", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:noabn) do
    TudlaAccounting::WithholdingCode.create!(organization: organization, code: "NOABN", name: "No ABN quoted", rate: "0.47", payable_account: account("2350"), withheld_on: "payment",
                                             exempt_up_to_cents: 75_00)
  end
  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GSTP", name: "GST on purchases", rate: "0.1", kind: :purchases, account: account("1300")) }
  let(:florist) { TudlaAccounting::Contact.create!(organization: organization, name: "Corner Florist", kind: "supplier", default_withholding_code: noabn) }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "1300", name: "GST paid", category: "asset" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "2350", name: "No-ABN withholding", category: "liability" }, { code: "6000", name: "Flowers", category: "expense" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def text(selector) = css_select(selector).map { |node| node.text.squish }
  def field(name) = css_select("[name='#{name}']").first

  def bill(cents, supplier: florist, tax_code: gst)
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 4, 1), due_on: Date.new(2026, 4, 30),
                                      lines_attributes: [ { description: "Flowers", unit_price_cents: cents, account: account("6000"), tax_code: tax_code } ]).approve!
  end

  def pay(payload)
    post routes.payments_path, params: { payment: { kind: "paid", contact_id: florist.id, account_id: account("1010").id, paid_on: "2026-04-15" }.merge(payload) }
    TudlaAccounting::Payment.where(organization: organization).order(:id).last
  end

  it "sets the limit on a code withheld on payment, from the no-ABN template, in the code form and the API" do
    TudlaAccounting::WithholdingCodeTemplates.add!(organization, "au_no_abn", payable_account: account("2350"))
    template = TudlaAccounting::WithholdingCode.find_by!(organization: organization, code: "NOABN")
    expect(template.exempt_up_to).to eq(Money.new(75_00, "AUD"))

    get routes.edit_withholding_code_path(template)
    expect(field("withholding_code[exempt_up_to]")["value"]).to eq("75.00")
    patch routes.withholding_code_path(template), params: { withholding_code: { exempt_up_to: "1,000.5" } }
    expect(template.reload.exempt_up_to_cents).to eq(1_000_50)
    patch routes.withholding_code_path(template), params: { withholding_code: { exempt_up_to: "abc" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(CGI.unescapeHTML(response.body)).to include("Exempt up to")
    patch routes.withholding_code_path(template), params: { withholding_code: { exempt_up_to: "" } }
    expect(template.reload.exempt_up_to_cents).to be_nil

    on_approval = TudlaAccounting::WithholdingCode.new(organization: organization, code: "WC010", name: "Professionals", rate: "0.1", payable_account: account("2350"), exempt_up_to_cents: 1_00)
    expect(on_approval).not_to be_valid
    expect(on_approval.errors[:exempt_up_to]).to eq([ "is only for a code withheld when the supplier is paid" ])
  end

  it "doesn't withhold from a supply of the limit or less before tax, saying why on the form, the payment and its JSON" do
    small = bill(70_00) # 77.00 with GST: 70.00 before it
    get routes.new_payment_path(document_id: small.id)
    expect([ field("payment[withholdings][0][withheld]")["value"], field("payment[amount]")["value"] ]).to eq([ nil, "77.00" ])
    expect(field("payment[not_withheld_reason]")["value"]).to eq("The supply on BILL-0001 is $75.00 or less before tax")

    payment = pay(amount: "77.00", applications: { small.id.to_s => "77.00" }, withholdings: { "0" => { withholding_code_id: noabn.id, withheld: "", base: "" } })
    expect(payment).to have_attributes(withheld_cents: 0, not_withheld_reason: "The supply on BILL-0001 is $75.00 or less before tax")
    get routes.payment_path(payment)
    expect(css_select("[data-details]").sole.text.squish).to include("Not withheld becauseThe supply on BILL-0001 is $75.00 or less before tax")

    large = bill(80_00)
    get routes.new_payment_path(document_id: large.id)
    expect(field("payment[withholdings][0][withheld]")["value"]).to eq("41.36") # 47% of 88.00
    expect(field("payment[not_withheld_reason]")["value"]).to be_nil
    paid_in_full = pay(amount: "88.00", applications: { large.id.to_s => "88.00" })
    expect(paid_in_full.not_withheld_reason).to eq("No reason given")
    typed = pay(amount: "10.00", not_withheld_reason: "  They quoted ABN 51 824 753 556 by phone ")
    expect(typed.not_withheld_reason).to eq("They quoted ABN 51 824 753 556 by phone")
    another = bill(80_00)
    withheld = pay(amount: "46.64", applications: { another.id.to_s => "88.00" }, withholdings: { "0" => { withholding_code_id: noabn.id, base: "88.00" } })
    expect(withheld).to have_attributes(withheld_cents: 41_36, not_withheld_reason: nil)
  end

  it "has nothing withheld from an exempt supplier, set on their contact with their statement's date" do
    get routes.edit_contact_path(florist)
    expect(css_select("select[name='contact[withholding_exemption]'] option").map(&:text)).to include("They're not exempt", "Not carrying on an enterprise")
    patch routes.contact_path(florist), params: { contact: { withholding_exemption: "no_enterprise", withholding_statement_on: "2026-03-03" } }
    expect(florist.reload).to have_attributes(withholding_exemption: "no_enterprise", withholding_statement_on: Date.new(2026, 3, 3))
    get routes.contact_path(florist)
    expect(css_select("[data-details]").sole.text.squish).to include("Not withheld fromNot carrying on an enterprise (their statement of 3 Mar 2026)")

    owed = bill(1_000_00)
    get routes.new_payment_path(document_id: owed.id)
    expect(field("payment[amount]")["value"]).to eq("1100.00")
    payment = pay(amount: "1100.00", applications: { owed.id.to_s => "1100.00" })
    expect(payment).to have_attributes(withheld_cents: 0, not_withheld_reason: "Not carrying on an enterprise (their statement of 3 Mar 2026)")

    patch routes.contact_path(florist), params: { contact: { withholding_exemption: "nope" } }
    expect(response).to have_http_status(:unprocessable_content)
    patch routes.contact_path(florist), params: { contact: { withholding_exemption: "", withholding_statement_on: "" } }
    expect(florist.reload.withholding_exemption_reason).to be_nil
    plain = TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier")
    expect(TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: plain, account: account("1010"), paid_on: Date.new(2026, 4, 15),
                                            amount_cents: 10_00, not_withheld_reason: "Ignored").not_withheld_reason).to be_nil # nothing to withhold from them
  end

  it "applies the limit and the exemption in pay runs and bank lines, keeping each reason" do
    small, large = bill(50_00), bill(1_000_00)
    painter = TudlaAccounting::Contact.create!(organization: organization, name: "Hobby Painter", kind: "supplier", default_withholding_code: noabn, withholding_exemption: "not_in_business")
    picture = bill(500_00, supplier: painter, tax_code: nil)
    get routes.new_pay_run_path(account_id: account("1010").id, due_by: "2026-05-31")
    expect(text("tbody[data-supplier] [data-withholding]")).to eq([ "· withhold NOABN (47%) from what is paid" ])
    expect(text("tbody[data-supplier] [data-not-withheld]")).to eq([ "· nothing withheld from some: the supply on BILL-0001 is $75.00 or less before tax",
                                                                     "· nothing withheld: not a business transaction: an individual not in business, or a private, domestic or hobby supply" ])

    post routes.pay_run_path, params: { pay_run: { account_id: account("1010").id, due_by: "2026-05-31", paid_on: "2026-04-15", reference: "Pay run",
                                                   pay: { small.id.to_s => "1", large.id.to_s => "1", picture.id.to_s => "1" },
                                                   amounts: { small.id.to_s => "55.00", large.id.to_s => "1100.00", picture.id.to_s => "500.00" } } }
    paid = TudlaAccounting::Payment.where(organization: organization).to_h { |payment| [ payment.contact.name, [ payment.amount_cents, payment.withheld_cents, payment.not_withheld_reason ] ] }
    expect(paid).to eq("Corner Florist" => [ 55_00 + 1_100_00 - 517_00, 517_00, "The supply on BILL-0001 is $75.00 or less before tax" ],
                       "Hobby Painter" => [ 500_00, 0, "Not a business transaction: an individual not in business, or a private, domestic or hobby supply" ])

    skipped, line_paid = bill(2_000_00), bill(60_00)
    post routes.pay_run_path, params: { pay_run: { account_id: account("1010").id, due_by: "2026-05-31", paid_on: "2026-04-15", pay: { skipped.id.to_s => "1" },
                                                   amounts: { skipped.id.to_s => "2200.00" }, withhold: { florist.id.to_s => "0" } } }
    expect(TudlaAccounting::Payment.order(:id).last).to have_attributes(withheld_cents: 0, not_withheld_reason: "Paid in full in a pay run")

    line = TudlaAccounting::BankStatementLine.create!(organization: organization, account: account("1010"), occurred_on: Date.new(2026, 4, 12), description: "FLORIST",
                                                      amount_cents: -66_00, currency: "AUD", external_id: "1")
    get routes.banking_account_path(account("1010"))
    expect(text("select#document_id_#{line.id} option")).to eq([ "BILL-0005 Corner Florist ($66.00 owed)" ])
    post routes.record_payment_bank_statement_line_path(line), params: { document_id: line_paid.id }
    expect(TudlaAccounting::Payment.order(:id).last).to have_attributes(amount_cents: 66_00, withheld_cents: 0, not_withheld_reason: "The supply on BILL-0005 is $75.00 or less before tax")
  end

  it "lists the payments made without withholding on the payee report, flagging those with no reason" do
    TudlaAccounting::PeriodCreator.call(organization, 2025)
    old = TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: florist, issued_on: Date.new(2025, 6, 1),
                                            lines_attributes: [ { description: "Flowers", unit_price_cents: 40_00, account: account("6000") } ]).approve!
    flowers = TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: florist, account: account("1010"), paid_on: Date.new(2025, 6, 2), amount_cents: 40_00,
                                               applications: [ { document: old, amount_cents: 40_00 } ])
    TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: florist, account: account("1010"), paid_on: Date.new(2025, 7, 2), amount_cents: 300_00)
    voided = TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: florist, account: account("1010"), paid_on: Date.new(2025, 8, 2), amount_cents: 20_00)
    voided.void!(on: Date.new(2025, 8, 3), reason: "Mistake")
    TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: florist, account: account("1010"), paid_on: Date.new(2025, 9, 2), amount_cents: 530_00,
                                     withholdings: [ { code: noabn, base_cents: 1_000_00 } ])

    get routes.reports_payee_payments_path
    expect(css_select("[data-not-withheld-row]").map { |row| row.css("td").map { |cell| cell.text.squish } })
      .to eq([ [ "2 Jun 2025", "Corner Florist", "40.00", "The supply on BILL-0001 is $75.00 or less before tax" ],
               [ "2 Jul 2025", "Corner Florist", "300.00", "No reason given" ] ])
    expect(css_select("[data-not-withheld-row] td.tc-negative").map(&:text)).to eq([ "No reason given" ])
    expect(css_select("[data-not-withheld-row] a").first["href"]).to eq(routes.payment_path(flowers))

    month = ->(number) { TudlaAccounting::Period.leaf_periods_for_date(organization, Time.zone.local(2026, number, 15, 12)).first }
    get routes.reports_payee_payments_path(from_id: month.call(1).id, thru_id: month.call(3).id)
    expect(response.body).not_to include("data-not-withheld")
  end

  it "takes and gives the reasons and exemptions in the API" do
    secret = TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: %w[read record post]).last
    headers = { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" }
    owed = bill(60_00)
    get routes.api_v1_pay_run_path(account_code: "1010"), headers: headers
    expect(response.parsed_body["data"]["bills"].sole).to include("withholding_code" => nil, "not_withheld_reason" => "The supply on BILL-0001 is $75.00 or less before tax")
    get routes.api_v1_withholding_codes_path, headers: headers
    expect(response.parsed_body["data"].sole["exempt_up_to"]).to eq("75.00")

    post routes.api_v1_payments_path, headers: headers, params: { kind: "paid", contact_id: florist.id, account_code: "1010", paid_on: "2026-04-15", amount: "500.00",
                                                                   not_withheld_reason: "Quoted an ABN on the quote" }.to_json
    expect(response.parsed_body["data"]).to include("not_withheld_reason" => "Quoted an ABN on the quote")
    expect(owed).to be_approved

    patch routes.api_v1_contact_path(florist), headers: headers, params: { withholding_exemption: "input_taxed", withholding_statement_on: "2026-02-01" }.to_json
    expect(response.parsed_body["data"]).to include("withholding_exemption" => "input_taxed", "withholding_statement_on" => "2026-02-01")
    patch routes.api_v1_contact_path(florist), headers: headers, params: { withholding_exemption: nil, withholding_statement_on: nil }.to_json
    expect(response.parsed_body["data"]).to include("withholding_exemption" => nil, "withholding_statement_on" => nil)
  end
end
