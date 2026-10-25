require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Invoices and bills in another currency", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post] }
  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200")) }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", email: "ap@northwind.test") }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }, { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def cells(selector) = css_select(selector).map { |row| row.css("td").map { |cell| cell.text.squish } }

  def invoice_params(**extra)
    { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-04-10", due_on: "2026-04-24", currency: "EUR", exchange_rate: "1.6",
      lines: { "0" => { description: "Consulting", quantity: "1", unit_price: "1,000.00", account_id: account("4000").id, tax_code_id: gst.id },
               "1" => { description: "Travel", quantity: "1", unit_price: "33.33", account_id: account("4000").id } } }.merge(extra)
  end

  it "posts a euro invoice converted at its rate to a euro receivables account, and shows it in euros" do
    get routes.new_document_path(kind: "sales_invoice")
    expect(css_select("select[name='document[currency]'] option").first.text).to eq("AUD – Australian Dollar")
    expect(css_select("[data-document-lines-target=rate][hidden]")).not_to be_empty

    post routes.documents_path, params: { approve: "1", document: invoice_params }
    invoice = TudlaAccounting::Document.sole
    expect(invoice).to have_attributes(currency: "EUR", exchange_rate: 1.6, total_cents: 1_133_33, total: Money.new(1_133_33, "EUR"))

    euros = account("1100-EUR")
    expect(euros).to have_attributes(parent: account("1100"), currency: "EUR")
    expect(invoice.entry.details.map { |detail| [ detail.account.code, detail.amount_cents, detail.foreign_exchange&.other_currency_cents ] })
      .to contain_exactly([ "1100-EUR", 1_813_33, 1_133_33 ], [ "4000", 1_600_00, nil ], [ "2200", 160_00, nil ], [ "4000", 53_33, nil ])
    expect(invoice.carrying_amount.forex).to have_attributes(other_currency: "EUR", other_currency_amount_cents: 1_133_33, transaction_rate: 1.6)
    expect([ invoice.amount_due, invoice.amount_due_in_base ]).to eq([ Money.new(1_133_33, "EUR"), Money.new(1_813_33, "AUD") ])

    get routes.document_path(invoice)
    expect(css_select("[data-exchange-rate]").first.text.squish).to eq("In EUR at 1.6 AUD: 1,813.33 AUD posted")
    expect(css_select("[data-document] thead th").last.text).to eq("Amount (EUR)")
    expect(cells("[data-document] tfoot tr").last).to eq([ "Total", "1,133.33" ])
    expect(css_select("a[href='#{routes.new_payment_path(document_id: invoice.id)}']")).not_to be_empty

    get routes.sales_documents_path
    expect(cells("tr[data-document-row]").sole.values_at(5, 6)).to eq([ "EUR 1,133.33", "EUR 1,133.33" ])
    expect(cells("tfoot tr").last.second).to eq("1,813.33")
    get routes.sales_documents_path(format: :csv)
    expect(response.body.lines.last.chomp).to end_with("1033.33,100.00,1133.33,1133.33,Awaiting payment,EUR,1813.33")

    expect(TudlaAccounting::EmailDraft.for_document(invoice)[:message]).to include("for EUR 1,133.33,")
  end

  it "looks up the date's rate when none is given, and says when there is none" do
    post routes.documents_path, params: { document: invoice_params(exchange_rate: "") }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Exchange rate is needed: no EUR rate was found for 10 Apr 2026")
    expect(css_select("[data-document-lines-target=rate][hidden]")).to be_empty

    TudlaAccounting::ForexRate.create!(from: "EUR", to: "AUD", year: 2026, month: 4, day: 10, rate: "1.65")
    post routes.documents_path, params: { document: invoice_params(exchange_rate: "") }
    expect(TudlaAccounting::Document.sole.exchange_rate).to eq(1.65)

    post routes.documents_path, params: { document: invoice_params(exchange_rate: "lots") }
    expect(response.body).to include("lots isn&#39;t an exchange rate")
    post routes.documents_path, params: { document: invoice_params(exchange_rate: "-1") }
    expect(response.body).to include("Exchange rate must be more than zero")
  end

  it "keeps the organization's own currency as none, and refuses an unknown one" do
    post routes.documents_path, params: { document: invoice_params(currency: "AUD") }
    expect(TudlaAccounting::Document.sole).to have_attributes(currency: "AUD", exchange_rate: nil, foreign?: false)
    expect(TudlaAccounting::Document.sole[:currency]).to be_nil

    invoice = TudlaAccounting::Document.new(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 4, 10), currency: "XYZ", exchange_rate: 2,
                                            lines_attributes: [ { description: "x", unit_price_cents: 1, account: account("4000") } ])
    expect(invoice.tap(&:valid?).errors.full_messages).to eq([ "Currency is not a known currency code" ])
  end

  it "credits a euro invoice in euros, applying it, and keeps euro documents apart from payments and refunds in dollars" do
    post routes.documents_path, params: { approve: "1", document: invoice_params }
    invoice = TudlaAccounting::Document.sole
    get routes.new_document_path(credit: invoice.id)
    expect(css_select("select[name='document[currency]'][disabled] option[selected]").map(&:text)).to eq([ "EUR – Euro" ])
    expect(css_select("input[name='document[exchange_rate]']").first["value"]).to eq("1.6")

    post routes.documents_path, params: { approve: "1", document: invoice_params(kind: "sales_credit", credited_document_id: invoice.id,
                                                                                 lines: { "0" => { description: "Discount", quantity: "1", unit_price: "100", account_id: account("4000").id } }) }
    credit = TudlaAccounting::Document.find_by!(kind: "sales_credit")
    expect(TudlaAccounting::Document.with_open_cents.find(invoice.id).amount_due).to eq(Money.new(1_033_33, "EUR"))
    get routes.document_path(invoice)
    expect(cells("section[aria-labelledby=applied] tbody tr").sole.last).to eq("100.00")
    get routes.document_path(credit)
    expect(credit.reload.amount_due).to eq(Money.new(0, "EUR")) # all of it went to the invoice

    other = TudlaAccounting::Document.new(organization: organization, kind: "sales_credit", contact: northwind, issued_on: Date.new(2026, 4, 12), credited_document: invoice,
                                          lines_attributes: [ { description: "x", unit_price_cents: 1, account: account("4000") } ])
    expect(other.tap(&:valid?).errors.full_messages).to eq([ "Credited document is in EUR; a credit note for it must be too" ])

    payment = TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 4, 14), amount_cents: 50_00)
    expect(TudlaAccounting::Allocator.open_charges(payment.entry)).to be_empty
    expect {
      TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 4, 14), amount_cents: 50_00,
                                       applications: [ { document: invoice, amount_cents: 50_00 } ])
    }.to raise_error(ArgumentError, "#{invoice.number_label} is in EUR, and the payment is in AUD")
    expect {
      TudlaAccounting::Payment.record!(organization: organization, kind: "refund", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 4, 14), amount_cents: 1_00, refund_of: credit)
    }.to raise_error(ArgumentError, "#{credit.number_label} is in EUR, and the refund is in AUD")
  end

  it "posts a bill in US dollars to a US dollar payables account" do
    bill = TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: northwind, issued_on: Date.new(2026, 4, 10), currency: "usd", exchange_rate: "1.5",
                                             lines_attributes: [ { description: "Hosting", unit_price_cents: 100_00, account: account("6000") } ]).approve!
    expect(bill.entry.details.map { |detail| [ detail.account.code, detail.tally, detail.amount_cents ] }).to contain_exactly([ "2100-USD", "credit", 150_00 ], [ "6000", "debit", 150_00 ])
  end

  describe "through the API" do
    let(:secret) { TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: %w[read record post]).last }
    let(:headers) { { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" } }

    def json = JSON.parse(response.body)

    def create_invoice(**fields)
      post routes.api_v1_documents_path, headers: headers, params: {
        kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-04-10", approve: true, currency: "EUR", exchange_rate: "1.6",
        lines: [ { description: "Consulting", unit_price: "1000.5", account_code: "4000" } ]
      }.merge(fields).to_json
    end

    it "takes the currency and rate, and shows the amounts in it" do
      create_invoice
      expect(response).to have_http_status(:created)
      expect(json["data"]).to include("currency" => "EUR", "exchange_rate" => "1.6", "total" => "1000.50", "amount_due" => "1000.50", "amount_due_in_base" => "1600.80")
      expect(json.dig("data", "lines", 0, "unit_price")).to eq("1000.50")

      patch routes.api_v1_document_path(json.dig("data", "id")), headers: headers, params: { notes: "x" }.to_json
      expect(response).to have_http_status(:unprocessable_content)
      create_invoice(currency: "XYZ")
      expect(json.dig("error", "message")).to eq("Currency must be a currency code, such as \"EUR\"")
      create_invoice(exchange_rate: "fast")
      expect(json.dig("error", "message")).to eq("Exchange_rate must be a decimal number, such as \"1234.50\"")
    end
  end
end
