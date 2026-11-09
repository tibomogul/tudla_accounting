require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Tax customers withhold from payments", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }
  let(:code) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC160", name: "Services", rate: "0.02", creditable_account: account("1200")) }
  let(:customer) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", default_withholding_code: code) }

  before do
    travel_to Time.zone.local(2026, 5, 25, 9)
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "1200", name: "Creditable tax", category: "asset" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2300", name: "Withholding payable", category: "liability" }, { code: "4000", name: "Sales", category: "income" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def text(selector) = css_select(selector).map { |node| node.text.squish }
  def rows = TudlaAccounting::WithheldTax.where(organization: organization).order(:id)

  def invoice(cents: 11_200_00)
    TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: customer, issued_on: Date.new(2026, 3, 10),
                                      lines_attributes: [ { description: "Consulting", unit_price_cents: cents, account: account("4000") } ]).approve!
  end

  def receive(on: Date.new(2026, 3, 20), contact: customer, reference: "EFT 1")
    TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: contact, account: account("1010"), paid_on: on, amount_cents: 11_000_00, reference: reference,
                                     withholdings: [ { code: code, withheld_cents: 200_00 } ])
  end

  def paying(**attributes)
    { payment: { kind: "received", contact_id: customer.id, account_id: account("1010").id, paid_on: "2026-03-20", amount: "11000.00", **attributes } }
  end

  it "asks for tax withheld only on a payment received, once there's a code for it" do
    plain = TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "both")
    get routes.new_payment_path(kind: "received", contact_id: plain.id)
    expect(response.body).not_to include("data-withholdings")

    code
    get routes.new_payment_path(kind: "paid", contact_id: plain.id)
    expect(response.body).not_to include("data-withholdings")

    TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Payable only", rate: "0.02", payable_account: account("2300"))
    get routes.new_payment_path(kind: "received", contact_id: customer.id)
    expect(text("[data-withholdings] h2")).to eq([ "Tax withheld by Northwind" ])
    expect(response.body).to include("Cash received (PHP)")
    expect(css_select("[data-withholdings] select").first.css("option").map(&:text)).to eq([ "Choose a code", "WC160 (2%) Services" ])
    expect(css_select("[data-withholdings] select").map { |select| select.css("option[selected]").map(&:text) }).to eq([ [ "WC160 (2%) Services" ], [], [] ])
  end

  it "records it from the form, settling the invoice, and shows it on the payment and the receipt" do
    sold = invoice
    post routes.payments_path, params: paying(applications: { sold.id => "11200.00" },
                                              withholdings: { "0" => { withholding_code_id: code.id, withheld: "200.00", base: "" }, "1" => { withholding_code_id: "", withheld: "", base: "" } })
    payment = TudlaAccounting::Payment.where(organization: organization).sole
    expect(response).to redirect_to(routes.payment_path(payment))
    expect(sold.reload.payment_status).to eq("paid")
    expect(rows.sole).to have_attributes(base_cents: 10_000_00, withheld_cents: 200_00)

    follow_redirect!
    expect(text("[data-details] div")).to include("Tax withheld₱200.00", "Settles₱11,200.00")
    expect(text("[data-withheld-taxes] tbody td").first(3)).to eq([ "WC160 (2%)", "10,000.00", "200.00" ])
    expect(css_select("[data-certificate=waiting]").size).to eq(1)
    expect(text("[data-document] tfoot tr")).to eq([ "Total settled11,200.00", "Less tax you withheld, WC160(200.00)", "Total received11,000.00" ])
    expect(css_select("a").map { |link| link["href"] }).not_to include(routes.new_refund_path(payment_id: payment.id))
  end

  it "keeps what was typed when it can't be recorded, and says why" do
    code
    post routes.payments_path, params: paying(withholdings: { "0" => { withholding_code_id: "", withheld: "200.00", base: "9000.00" } })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(CGI.unescapeHTML(response.body)).to include("Choose a withholding code for the tax withheld")
    expect(css_select("input[name='payment[withholdings][0][withheld]']").first["value"]).to eq("200.00")
    expect(css_select("input[name='payment[withholdings][0][base]']").first["value"]).to eq("9000.00")
    expect(css_select("select[name='payment[withholdings][0][withholding_code_id]'] option[selected]")).to be_empty

    post routes.payments_path, params: paying(withholdings: { "0" => { withholding_code_id: code.id, withheld: "nonsense", base: "" } })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("(tax withheld)")
    post routes.payments_path, params: paying(withholdings: { "0" => { withholding_code_id: code.id, withheld: "1.00", base: "nonsense" } })
    expect(response.body).to include("(income)")
    expect(rows).to be_empty
  end

  it "offers a refund only of the cash, and adds the tax to the CSV" do
    payment = receive
    get routes.new_refund_path(payment_id: payment.id)
    expect(response.body).to include("₱11,000.00")
    expect(css_select("input[name='payment[amount]']").first["value"]).to eq("11000.00")

    get routes.received_payments_path(format: :csv)
    expect(response.body.lines.last.chomp).to end_with(",200.00")
    get routes.received_payments_path
    expect(css_select("a").map { |link| link["href"] }).to include(routes.withholding_certificates_path)
  end

  it "refuses to void a payment with its certificate marked, on the payment's page and the entry's" do
    payment = receive
    rows.sole.mark_certificate!(on: Date.new(2026, 4, 5))
    post routes.void_payment_path(payment), params: { on: "2026-04-06", reason: "Bounced" }
    follow_redirect!
    expect(CGI.unescapeHTML(response.body)).to include("It wasn't voided: the tax certificate for it is marked received; unmark it first.")
    expect(text("[data-withheld-taxes] td").last).to start_with("Received 5 Apr 2026")
    post routes.reverse_entry_path(payment.entry), params: { on: "2026-04-06" }
    follow_redirect!
    expect(CGI.unescapeHTML(response.body)).to include("unmark it first")
    expect(payment.reload).not_to be_void
  end

  it "shows a voided payment's amounts as reversed" do
    payment = receive
    payment.void!(on: Date.new(2026, 4, 6), reason: "Bounced")
    get routes.payment_path(payment)
    expect(text("[data-withheld-taxes] tbody tr").size).to eq(1)
    expect(text("[data-certificate]")).to eq([ "Reversed" ])
    get routes.withholding_certificates_path(show: "all")
    expect(css_select("[data-certificate-row]")).to be_empty
  end

  describe "the certificates page" do
    let(:other) { TudlaAccounting::Contact.create!(organization: organization, name: "Acme", kind: "customer") }

    it "is only for books in the Philippines, or with no country" do
      payment = receive
      headers = { "Authorization" => "Bearer #{TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: %w[read post]).last}" }
      TudlaAccounting.configuration.country = "AU"
      get routes.withholding_certificates_path
      expect(response).to have_http_status(:not_found)
      post routes.mark_withholding_certificate_path(rows.sole), params: { on: "2026-04-10" }
      expect(response).to have_http_status(:not_found)
      post "#{routes.api_v1_payments_path.delete_suffix('/payments')}/withheld_taxes/#{rows.sole.id}/certificate", params: { on: "2026-04-10" }, headers: headers
      expect(response).to have_http_status(:not_found)
      get routes.payment_path(payment)
      expect(text("[data-withheld-taxes] thead th")).not_to include("Certificate")
      expect(css_select("[data-certificate]")).to be_empty
      get routes.received_payments_path
      expect(css_select("a").map(&:text)).not_to include("Tax certificates")
      expect(rows.sole.certificate_received_on).to be_nil

      TudlaAccounting.configuration.country = "PH"
      get routes.withholding_certificates_path
      expect(response).to have_http_status(:ok)
      get routes.payment_path(payment)
      expect(css_select("[data-certificate=waiting]").size).to eq(1)
      get routes.received_payments_path
      expect(css_select("a").map(&:text)).to include("Tax certificates")
      post "#{routes.api_v1_payments_path.delete_suffix('/payments')}/withheld_taxes/#{rows.sole.id}/certificate", params: { on: "2026-04-10" }, headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "lists what is waiting by customer and quarter, oldest first, and filters" do
      get routes.withholding_certificates_path
      expect(response.body).to include("No certificates to chase.")
      get routes.withholding_certificates_path(show: "received")
      expect(response.body).to include("Nothing to show.")

      receive
      receive(on: Date.new(2026, 3, 25), reference: nil)
      receive(on: Date.new(2026, 4, 2))
      receive(contact: other)

      get routes.withholding_certificates_path
      expect(text("[data-certificate-group] h2")).to eq([ "Acme, Jan–Mar 2026", "Northwind, Jan–Mar 2026", "Northwind, Apr–Jun 2026" ])
      group = css_select("[data-certificate-group]")[1]
      expect(group.css("[data-certificate-row]").size).to eq(2)
      expect(group.css("[data-certificate-row]").last.css("td")[1].text.squish).to eq("Payment from Northwind")
      expect(group.css("tfoot td").map { |cell| cell.text.squish }).to eq([ "Total", "20,000.00", "400.00", "" ])
      expect(group.css("input[type=submit]").first["value"]).to eq("Mark all 2 received")
      expect(css_select("[data-certificate-group]")[0].text).not_to include("Mark all")

      get routes.withholding_certificates_path(contact_id: other.id)
      expect(text("[data-certificate-group] h2")).to eq([ "Acme, Jan–Mar 2026" ])
    end

    it "marks one received, moves it to the received list, and unmarks it" do
      receive
      row = rows.sole
      post routes.mark_withholding_certificate_path(row), params: { on: "2026-04-05" }
      expect(response).to redirect_to(routes.withholding_certificates_path)
      expect(flash[:notice]).to eq("Certificate marked received.")
      expect(row.reload.certificate_received_on).to eq(Date.new(2026, 4, 5))

      get routes.withholding_certificates_path
      expect(css_select("[data-certificate-row]")).to be_empty
      get routes.withholding_certificates_path(show: "received")
      expect(text("[data-certificate]").sole).to start_with("Received 5 Apr 2026")

      post routes.mark_withholding_certificate_path(row), params: { on: "2026-04-06" }
      expect(flash[:alert]).to eq("It wasn't marked: this certificate is marked received already.")

      post routes.unmark_withholding_certificate_path(row)
      expect(flash[:notice]).to eq("Certificate unmarked.")
      expect(row.reload.certificate_received_on).to be_nil
      post routes.unmark_withholding_certificate_path(row)
      expect(flash[:alert]).to eq("It wasn't unmarked: this certificate isn't marked received.")
      post routes.mark_withholding_certificate_path(row), params: { on: "nonsense" }
      expect(flash[:alert]).to start_with("It wasn't marked:")
    end

    it "marks a customer's whole quarter, leaving other quarters and customers" do
      march, later_march, april = receive, receive(on: Date.new(2026, 3, 25)), receive(on: Date.new(2026, 4, 2))
      someone_else = receive(contact: other)
      post routes.mark_all_withholding_certificates_path, params: { contact_id: customer.id, quarter: "2026-01-01", on: "2026-04-05" }
      expect(flash[:notice]).to eq("2 certificate amounts marked received.")
      marked = ->(payment) { rows.find_by!(payment: payment).certificate_received_on }
      expect([ marked.call(march), marked.call(later_march) ]).to all(eq(Date.new(2026, 4, 5)))
      expect([ marked.call(april), marked.call(someone_else) ]).to all(be_nil)

      post routes.mark_all_withholding_certificates_path, params: { contact_id: customer.id, quarter: "nonsense", on: "2026-04-05" }
      expect(flash[:alert]).to start_with("They weren't marked:")
    end

    it "needs permission to post to change them, and shows them without it" do
      receive
      row = rows.sole
      TudlaAccounting.configuration.authorize = ->(_controller, permission) { permission == :read }
      get routes.withholding_certificates_path
      expect(response).to have_http_status(:ok)
      expect(text("[data-certificate]")).to eq([ "Waiting" ])
      post routes.mark_withholding_certificate_path(row), params: { on: "2026-04-05" }
      expect(response).to have_http_status(:forbidden)
      post routes.mark_all_withholding_certificates_path, params: { contact_id: customer.id, quarter: "2026-01-01", on: "2026-04-05" }
      expect(response).to have_http_status(:forbidden)
      expect(row.reload.certificate_received_on).to be_nil
    end

    it "shows on the activity page" do
      payment = receive
      rows.sole.mark_certificate!(on: Date.new(2026, 4, 5))
      rows.sole.unmark_certificate!
      get routes.activity_path(kind: "withheld_tax")
      expect(CGI.unescapeHTML(response.body)).to include("Marked the WC160 certificate received on 5 Apr 2026 for", "Unmarked the WC160 certificate for", payment.title)
    end
  end
end
