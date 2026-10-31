require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Payments in another currency", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post] }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both") }

  before do
    travel_to Time.zone.local(2026, 4, 20, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1050", name: "Euro account", category: "asset", currency: "EUR" },
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "4000", name: "Sales", category: "income" }, { code: "4950", name: "Exchange gains", category: "income", role: "realized_fx_gain" },
      { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def cells(selector) = css_select(selector).map { |row| row.css("td").map { |cell| cell.text.squish } }
  def options(name) = css_select("select[name='#{name}'] option").map(&:text)
  def gains = TudlaAccounting::Detail.where(account: account("4950")).map { |detail| [ detail.tally, detail.amount_cents ] }

  def document(kind = "sales_invoice", cents: 1_000_00, rate: "1.6", currency: "EUR", on: Date.new(2026, 4, 10))
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: northwind, issued_on: on, currency: currency, exchange_rate: rate,
                                      lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account(kind == "bill" ? "6000" : "4000") } ]).approve!
  end

  def record(**attributes)
    TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1050"), paid_on: Date.new(2026, 4, 18), **attributes)
  end

  it "records a euro payment of a euro invoice from its page, posting the exchange gain, and shows it in euros" do
    invoice = document
    home = document(currency: nil, rate: nil, cents: 50_00)
    get routes.new_payment_path(document_id: invoice.id)
    expect(options("payment[account_id]")).to eq([ "Choose an account", "1050 - Euro account" ])
    expect(css_select("input[name='payment[amount]']").first["value"]).to eq("1000.00")
    expect(css_select("label[for=payment_amount]").first.text).to eq("Amount (EUR)")
    expect(cells("tr[data-open-document]").map(&:first)).to eq([ invoice.number_label ])

    post routes.payments_path, params: { payment: { kind: "received", contact_id: northwind.id, account_id: account("1050").id, paid_on: "2026-04-18", amount: "1,000",
                                                    exchange_rate: "1.65", applications: { invoice.id.to_s => "1000.00", home.id.to_s => "" } } }
    payment = TudlaAccounting::Payment.sole
    expect(response).to redirect_to(routes.payment_path(payment))
    expect(payment).to have_attributes(currency: "EUR", exchange_rate: 1.65, amount: Money.new(1_000_00, "EUR"), unapplied: Money.new(0, "EUR"))
    expect(payment.entry.details.map { |detail| [ detail.account.code, detail.amount_cents, detail.foreign_exchange&.other_currency_cents ] })
      .to contain_exactly([ "1050", 1_650_00, 1_000_00 ], [ "1100-EUR", 1_650_00, 1_000_00 ])
    expect(TudlaAccounting::Document.with_open_cents.find(invoice.id)).to have_attributes(payment_status: "paid", amount_due_in_base: Money.new(0, "AUD"))
    expect(gains).to eq([ [ "credit", 50_00 ] ]) # received 1,650 for what was booked at 1,600

    get routes.payment_path(payment)
    expect(css_select("[data-exchange-rate]").first.text.squish).to eq("In EUR at 1.65 AUD: 1,650.00 AUD posted")
    expect(cells("[data-document] tfoot tr").last).to eq([ "Total received", "1,000.00" ])
    expect(css_select("[data-document] thead th").last.text).to eq("Amount (EUR)")
    get routes.received_payments_path
    expect(cells("tr[data-payment-row]").sole[4]).to eq("EUR 1,000.00")
    get routes.received_payments_path(format: :csv)
    expect(response.body.lines.last.chomp).to end_with("Payment received,EUR")

    statement = TudlaAccounting::PartyStatement.call(organization: organization, type: :receivable, party: northwind, from: Date.new(2026, 4, 1), thru: Date.new(2026, 4, 30))
    expect(statement.lines.filter_map(&:foreign)).to eq([ Money.new(1_000_00, "EUR"), Money.new(-1_000_00, "EUR") ])
  end

  it "offers payments in each bank account's currency, with only what is owed in it" do
    document
    get routes.new_payment_path(kind: "received", contact_id: northwind.id)
    expect(options("currency")).to eq([ "Their currency", "AUD", "EUR" ])
    expect(options("payment[account_id]")).to eq([ "Choose an account", "1000 - Bank" ])
    expect(css_select("tr[data-open-document]")).to be_empty
    expect(css_select("input[name='payment[exchange_rate]']")).to be_empty

    get routes.new_payment_path(kind: "received", contact_id: northwind.id, currency: "EUR")
    expect(css_select("tr[data-open-document]").size).to eq(1)
    expect(css_select("input[name='payment[exchange_rate]']")).not_to be_empty

    post routes.payments_path, params: { payment: { kind: "received", contact_id: northwind.id, account_id: account("1050").id, paid_on: "2026-04-18", amount: "10", exchange_rate: "x" } }
    expect(response.body).to include("x isn&#39;t an exchange rate")
    expect(css_select("label[for=payment_amount]").first.text).to eq("Amount (EUR)")

    expect { record(account: account("1100-EUR"), amount_cents: 1_00, exchange_rate: 1) }.to raise_error(ArgumentError, "Account must be a bank or cash account")
    expect { record(account: account("1000"), amount_cents: 1_00, applications: [ { document: TudlaAccounting::Document.sole, amount_cents: 1_00 } ]) }
      .to raise_error(ArgumentError, "#{TudlaAccounting::Document.sole.number_label} is in EUR, and the payment is in AUD")
  end

  it "starts a payment in the contact's currency, when the books can pay in it" do
    document
    northwind.update!(currency: "EUR")
    get routes.new_payment_path(kind: "received", contact_id: northwind.id)
    expect(css_select("label[for=payment_amount]").first.text).to eq("Amount (EUR)")
    expect(css_select("tr[data-open-document]").size).to eq(1)
    expect(css_select("select[name=currency] option[selected]")).to be_empty # "Their currency"
    get routes.new_payment_path(kind: "received", contact_id: northwind.id, currency: "AUD")
    expect(css_select("label[for=payment_amount]").first.text).to eq("Amount (AUD)")

    northwind.update!(currency: "USD") # no bank account in it
    get routes.new_payment_path(kind: "received", contact_id: northwind.id)
    expect(css_select("label[for=payment_amount]").first.text).to eq("Amount (AUD)")
  end

  it "keeps an overpayment as a euro credit, refunds it in euros, and pays a euro bill at a loss" do
    invoice = document
    payment = record(amount_cents: 1_200_00, exchange_rate: "1.6", applications: [ { document: invoice, amount_cents: 1_000_00 } ])
    expect(payment.unapplied).to eq(Money.new(200_00, "EUR"))
    expect(payment.applications.map(&:second)).to eq([ Money.new(1_000_00, "EUR") ])
    expect(gains).to be_empty

    get routes.new_refund_path(payment_id: payment.id)
    expect(options("payment[account_id]")).to eq([ "Choose an account", "1050 - Euro account" ])
    expect(css_select("input[name='payment[amount]']").first["value"]).to eq("200.00")
    post routes.refunds_path, params: { payment_id: payment.id, payment: { account_id: account("1050").id, paid_on: "2026-04-19", amount: "200", exchange_rate: "1.7" } }
    refund = TudlaAccounting::Payment.find_by!(kind: "refund")
    expect(refund).to have_attributes(currency: "EUR", amount: Money.new(200_00, "EUR"))
    expect(payment.reload.unapplied).to eq(Money.new(0, "EUR"))
    post routes.refunds_path, params: { payment_id: payment.id, payment: { account_id: account("1050").id, paid_on: "2026-04-19", amount: "1", exchange_rate: "nope" } }
    expect(response.body).to include("nope isn&#39;t an exchange rate")

    bill = document("bill", cents: 100_00, rate: "1.5")
    TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: northwind, account: account("1050"), paid_on: Date.new(2026, 4, 18), amount_cents: 100_00,
                                     exchange_rate: "1.6", applications: [ { document: bill, amount_cents: 100_00 } ])
    expect(gains).to include([ "debit", 10_00 ]) # paid 160 for what was booked at 150
  end

  describe "through the API" do
    let(:secret) { TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: %w[read record post]).last }
    let(:headers) { { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" } }

    def json = JSON.parse(response.body)

    it "takes amounts in the bank account's currency, and applies a euro credit in euros" do
      first, second = document, document(cents: 300_00)
      post routes.api_v1_payments_path, headers: headers, params: { kind: "received", contact_id: northwind.id, account_code: "1050", paid_on: "2026-04-18", amount: "1200",
                                                                    exchange_rate: "1.65", applications: [ { document_id: first.id, amount: "1000" } ] }.to_json
      expect(response).to have_http_status(:created)
      expect(json["data"]).to include("currency" => "EUR", "exchange_rate" => "1.65", "amount" => "1200.00", "unapplied" => "200.00")
      expect(json.dig("data", "applied", 0, "amount")).to eq("1000.00")

      post routes.apply_api_v1_payment_path(json.dig("data", "id")), headers: headers, params: { document_id: second.id, amount: "150", on: "2026-04-19" }.to_json
      expect(response).to have_http_status(:created)
      expect(json.dig("data", "unapplied")).to eq("50.00")
      expect(TudlaAccounting::Document.with_open_cents.find(second.id).amount_due).to eq(Money.new(150_00, "EUR"))
    end
  end
end
