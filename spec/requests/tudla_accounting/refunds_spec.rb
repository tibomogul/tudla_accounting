require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Applying credits and refunding them", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post] }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both") }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "4000", name: "Sales", category: "income" },
      { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def aud(amount) = Money.from_amount(amount, "AUD")

  def document(kind, cents, contact: northwind, issued_on: Date.new(2026, 4, 1))
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: contact, issued_on: issued_on,
                                      lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account(kind.in?(%w[bill supplier_credit]) ? "6000" : "4000") } ]).approve!
  end

  def pay(kind, cents, applications = [], contact: northwind)
    TudlaAccounting::Payment.record!(organization: organization, kind: kind, contact: contact, account: account("1000"), paid_on: Date.new(2026, 4, 10),
                                     amount_cents: cents, applications: applications)
  end

  def postings(entry) = entry.details.map { |detail| [ detail.account.code, detail.tally == TudlaAccounting::Detail::TALLY_DEBIT ? :debit : :credit, detail.amount_cents ] }.sort

  it "applies an overpayment to another invoice from the payment's page, refunds the rest, and voids the refund" do
    first = document("sales_invoice", 100_00)
    second = document("sales_invoice", 30_00)
    payment = pay("received", 150_00, [ { document: first, amount_cents: 100_00 } ])

    get routes.payment_path(payment)
    expect(css_select("[data-apply-credit] select option").map(&:text)).to contain_exactly(a_string_including("INV-0002"))
    expect(css_select("a[href='#{routes.new_refund_path(payment_id: payment.id)}']").map(&:text)).to eq([ "Refund to them" ])
    post routes.allocations_path, params: { entry_id: payment.entry_id, to_id: second.entry.details.filter_map(&:carrying_amount).first.id, back: routes.payment_path(payment) }
    expect(response).to redirect_to(routes.payment_path(payment))
    expect(payment.reload.unapplied).to eq(aud(20))
    expect(second.reload.amount_due).to eq(aud(0))

    get routes.new_refund_path(payment_id: payment.id)
    expect(css_select("h1").first.text).to eq("Refund to Northwind")
    expect(css_select("input[name='payment[amount]']").first["value"]).to eq("20.00")
    post routes.refunds_path, params: { payment_id: payment.id, payment: { account_id: account("1000").id, paid_on: "2026-04-14", amount: "25.00" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(css_select("[role=alert]").text.squish).to eq("Only $20.00 of the payment from Northwind on 10 Apr 2026 is left to refund")

    post routes.refunds_path, params: { payment_id: payment.id, payment: { account_id: account("1000").id, paid_on: "2026-04-14", amount: "20.00", reference: "EFT 9" } }
    refund = TudlaAccounting::Payment.find_by!(kind: "refund")
    expect(response).to redirect_to(routes.payment_path(refund))
    expect(flash[:notice]).to eq("Refund to Northwind of $20.00 recorded.")
    expect(refund).to have_attributes(title: "Refund to Northwind", refund_of: payment, unapplied: aud(0), applications: [])
    expect(postings(refund.entry)).to eq([ [ "1000", :credit, 20_00 ], [ "1100", :debit, 20_00 ] ])
    expect(payment.reload.unapplied).to eq(aud(0))
    expect(payment.applications.map { |target, amount, _allocation| [ target, amount.cents ] }).to eq([ [ first, 100_00 ], [ refund, 20_00 ], [ second, 30_00 ] ]) # by date

    get routes.payment_path(refund)
    expect(css_select("[data-details] > div").map { |row| row.css("span").map(&:text) }).to eq([ [ "To", "Northwind" ], [ "Out of", "1000 - Bank" ], [ "Reference", "EFT 9" ], [ "Amount", "$20.00" ], [ "Pays back", "Payment from Northwind" ] ])
    expect(response.body).not_to include("Email receipt", "as it prints")
    get routes.payment_path(payment)
    expect(response.body).not_to include("Refund to them")
    expect(css_select("#applied ~ table td a").map(&:text)).to include("Refund to Northwind")
    expect(css_select("#notice-heading ~ * tbody tr").map { |row| row.text.squish }).to include("Refunded to you (EFT 9) 14 Apr 2026 20.00")
    get routes.received_payments_path
    expect(css_select("tr[data-payment-row]").map { |row| row.text.squish }).to include(a_string_including("Northwind EFT 9 1000 - Bank 20.00 Refund"))
    get routes.received_payments_path(format: :csv)
    expect(CSV.parse(response.body).map { |row| row[-2] }).to eq([ "Kind", "Refund to customer", "Payment received" ])
    get routes.payment_path(refund, format: :pdf)
    expect(response).to have_http_status(:not_found)
    get routes.new_email_path(payment_id: refund.id)
    expect(response).to have_http_status(:not_found)
    get routes.reports_statement_path(type: "receivable", party: TudlaAccounting::PartyStatement.key(northwind), from: "2026-04-01", thru: "2026-04-30")
    expect(css_select("tbody tr").map { |row| row.text.squish }).to include(a_string_including("Refund to Northwind", "20.00"))
    get routes.activity_path(kind: "payment")
    expect(response.body).to include("paying back the payment from Northwind on 10 Apr 2026")

    post routes.void_payment_path(refund), params: { on: "2026-04-15", reason: "Bounced" }
    expect(payment.reload.unapplied).to eq(aud(20))
    get routes.new_refund_path(payment_id: payment.id)
    expect(response).to have_http_status(:ok)
  end

  it "applies a supplier's credit note from the contact's page, and records their refund of another" do
    bill = document("bill", 100_00)
    credit = document("supplier_credit", 40_00)
    get routes.document_path(credit)
    expect(css_select("#apply-credit").text).to include("Left to apply: 40.00")
    expect(response.body).to include("Record their refund")

    get routes.contact_path(northwind)
    expect(css_select("[data-open='payable'] form button").map(&:text)).to eq([ "Apply oldest first" ])
    post routes.oldest_first_allocations_path, params: { entry_id: credit.entry_id, back: routes.contact_path(northwind) }
    expect(response).to redirect_to(routes.contact_path(northwind))
    expect(bill.reload.amount_due).to eq(aud(60))
    get routes.document_path(credit)
    expect(response.body).not_to include("apply-credit", "Record their refund")
    get routes.new_refund_path(document_id: credit.id)
    expect(response).to redirect_to(routes.document_path(credit))
    expect(flash[:alert]).to eq("Nothing is left of it to refund.")

    another = document("supplier_credit", 10_00)
    get routes.contact_path(northwind)
    expect(css_select("a[href='#{routes.new_refund_path(document_id: another.id)}']").map(&:text)).to eq([ "Refund" ])
    get routes.new_refund_path(document_id: another.id)
    expect(css_select("h1").first.text).to eq("Refund from Northwind")
    post routes.refunds_path, params: { document_id: another.id, payment: { account_id: account("1000").id, paid_on: "2026-04-14", amount: "10.00" } }
    refund = TudlaAccounting::Payment.find_by!(kind: "supplier_refund")
    expect(refund).to have_attributes(title: "Refund from Northwind", refund_of: another)
    expect(refund.entry.particulars).to eq("Refund from Northwind (SC-0002)")
    expect(postings(refund.entry)).to eq([ [ "1000", :debit, 10_00 ], [ "2100", :credit, 10_00 ] ])
    expect(another.reload.amount_due).to eq(aud(0))
    get routes.document_path(another)
    expect(css_select("#applied").first.parent.text).to include("Refund from Northwind")
    get routes.paid_payments_path
    expect(css_select("tr[data-payment-row]").size).to eq(1)

    post routes.refunds_path, params: { document_id: another.id, payment: { account_id: account("1000").id, paid_on: "2026-04-14", amount: "x" } }
    expect(css_select("[role=alert]").text.squish).to eq("x isn't an amount")
  end

  it "refunds only what is the contact's own credit to refund" do
    other = TudlaAccounting::Contact.create!(organization: organization, name: "Globex")
    payment = pay("received", 50_00)
    invoice = document("sales_invoice", 10_00)
    refund = ->(**extra) { TudlaAccounting::Payment.record!(organization: organization, kind: "refund", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 4, 12), amount_cents: 10_00, **extra) }
    expect { refund.call }.to raise_error(ArgumentError, "Choose the payment or credit note it pays back")
    expect { refund.call(refund_of: invoice) }.to raise_error(ArgumentError, "Invoice INV-0001 isn't a credit of Northwind's to refund")
    expect { refund.call(refund_of: pay("received", 50_00, contact: other)) }.to raise_error(ArgumentError, "Payment from Globex isn't a credit of Northwind's to refund")
    expect { refund.call(refund_of: pay("paid", 50_00)) }.to raise_error(ArgumentError, "Payment to Northwind isn't a credit of Northwind's to refund")
    expect { refund.call(refund_of: payment, applications: [ { document: invoice, amount_cents: 10_00 } ]) }.to raise_error(ArgumentError, "A refund isn't applied to invoices or bills")
    expect { pay("received", 50_00).then { |made| TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 4, 12), amount_cents: 1, refund_of: made) } }
      .to raise_error(ArgumentError, "Only a refund pays a credit back")
    payment.void!(on: Date.new(2026, 4, 12), reason: "Wrong")
    expect { refund.call(refund_of: payment) }.to raise_error(ArgumentError, "Payment from Northwind isn't a credit of Northwind's to refund")
    expect(TudlaAccounting::Payment.where(kind: "refund")).to be_empty

    get routes.new_refund_path(payment_id: payment.id)
    expect(response).to have_http_status(:not_found)
  end

  context "without permission to post" do
    let(:permissions) { %i[read record] }

    it "offers no refunds or applying" do
      payment = pay("received", 50_00)
      document("sales_invoice", 10_00)
      get routes.payment_path(payment)
      expect(response.body).not_to include("Refund to them", "data-apply-credit")
      get routes.new_refund_path(payment_id: payment.id)
      expect(response).to have_http_status(:forbidden)
    end
  end
end

RSpec.describe "JSON API: applying credits and refunds", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %w[read post] }
  let(:secret) { TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: permissions).last }
  let(:headers) { { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" } }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
                                            { code: "4000", name: "Sales", category: "income" } ], organization)
  end

  def json = JSON.parse(response.body)
  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def document(kind, cents)
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: northwind, issued_on: Date.new(2026, 4, 1),
                                      lines_attributes: [ { description: "Work", unit_price_cents: cents, account: account("4000") } ]).approve!
  end

  def payment(cents) = TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 4, 10), amount_cents: cents)

  it "applies a payment and a credit note to invoices" do
    invoice = document("sales_invoice", 100_00)
    paid = payment(60_00)
    post routes.apply_api_v1_payment_path(paid), params: { document_id: invoice.id, amount: "25.00", on: "2026-04-12" }.to_json, headers: headers
    expect(response).to have_http_status(:created)
    expect(json["data"]).to include("unapplied" => "35.00", "applied" => [ include("document_id" => invoice.id, "number" => "INV-0001", "amount" => "25.00", "payment_id" => nil) ])

    credit = document("sales_credit", 30_00)
    post routes.apply_api_v1_document_path(credit), params: { document_id: invoice.id }.to_json, headers: headers
    expect(json["data"]).to include("amount_due" => "0.00")
    expect(invoice.reload.amount_due.cents).to eq(45_00)

    post routes.apply_api_v1_payment_path(paid), params: {}.to_json, headers: headers
    expect(json.dig("error", "message")).to eq("Document_id is missing")
    post routes.apply_api_v1_payment_path(paid), params: { document_id: credit.id }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(json.dig("error", "message")).to eq("Credit note CN-0001 isn't owed anything it could be applied to")
  end

  it "refunds a payment or credit note" do
    paid = payment(60_00)
    credit = document("sales_credit", 30_00)
    record = ->(refund_of, amount = "10.00") do
      post routes.api_v1_payments_path, params: { kind: "refund", contact_id: northwind.id, account_code: "1000", paid_on: "2026-04-12", amount: amount, refund_of: refund_of }.to_json, headers: headers
    end
    record.call({ payment_id: paid.id })
    expect(response).to have_http_status(:created)
    expect(json["data"]).to include("kind" => "refund", "refund_of" => { "payment_id" => paid.id }, "unapplied" => "0.00")
    refund_id = json.dig("data", "id")
    get routes.api_v1_payment_path(paid), headers: headers
    expect(json.dig("data", "applied")).to match([ include("payment_id" => refund_id, "document_id" => nil, "amount" => "10.00") ])

    record.call({ document_id: credit.id }, "30.00")
    expect(json.dig("data", "refund_of")).to eq("document_id" => credit.id)
    record.call({ document_id: credit.id, payment_id: paid.id })
    expect(json.dig("error", "message")).to eq("Refund_of must be an object with payment_id or document_id")
    record.call("x")
    expect(response).to have_http_status(:unprocessable_content)
  end

  context "with a read-only token" do
    let(:permissions) { %w[read] }

    it "can't apply" do
      post routes.apply_api_v1_payment_path(payment(10_00)), params: { document_id: document("sales_invoice", 10_00).id }.to_json, headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
