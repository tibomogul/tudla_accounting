require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"
require_relative "../../support/test_jobs"

RSpec.describe "Pay runs", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include_context "with the test job adapter"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post] }
  let(:cloudware) { TudlaAccounting::Contact.create!(organization: organization, name: "Cloudware", kind: "supplier", email: "ar@cloudware.test") }
  let(:stationers) { TudlaAccounting::Contact.create!(organization: organization, name: "Stationers", kind: "supplier") }

  before do
    travel_to Time.zone.local(2026, 4, 20, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    TudlaAccounting.configuration.document_mail_from = "accounts@acme.test"
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1050", name: "Euro account", category: "asset", currency: "EUR" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "4950", name: "Exchange gains", category: "income", role: "realized_fx_gain" },
      { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def listed = css_select("tbody[data-supplier]").to_h { |group| [ group["data-supplier"], group.css("tr[data-bill] td:nth-child(2)").map { |cell| cell.text.squish } ] }

  def bill(supplier, due_on, cents, currency: nil, rate: nil)
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 4, 1), due_on: due_on, currency: currency, exchange_rate: rate,
                                      lines_attributes: [ { description: "Supplies", unit_price_cents: cents, account: account("6000") } ]).approve!
  end

  def pay(bills, **fields)
    post routes.pay_run_path, params: { pay_run: { account_id: account("1000").id, due_by: "2026-04-27", paid_on: "2026-04-20", reference: "Pay run 20 Apr", email: "1",
                                                   pay: bills.to_h { |bill, _| [ bill.id.to_s, "1" ] }, amounts: bills.to_h { |bill, amount| [ bill.id.to_s, amount.to_s ] } }.merge(fields) }
  end

  it "lists the bills due by a date, by supplier, from the account's currency" do
    first = bill(cloudware, Date.new(2026, 4, 15), 100_00)
    second = bill(cloudware, Date.new(2026, 4, 25), 200_00)
    other = bill(stationers, Date.new(2026, 4, 18), 50_00)
    bill(stationers, Date.new(2026, 5, 30), 70_00) # not due yet
    euros = bill(cloudware, Date.new(2026, 4, 10), 30_00, currency: "EUR", rate: "1.6")

    get routes.purchase_documents_path
    expect(css_select("a[href='#{routes.new_pay_run_path}']")).not_to be_empty
    get routes.new_pay_run_path
    expect(listed).to eq("Cloudware" => [ first.number_label, second.number_label ], "Stationers" => [ other.number_label ])
    expect(css_select("input[name^='pay_run[pay]'][checked]").size).to eq(3)
    expect(css_select("input[name='pay_run[due_by]']").first["value"]).to eq("2026-04-27")
    expect(response.body).to include("no email address")

    get routes.new_pay_run_path(due_by: "2026-06-30", contact_id: stationers.id)
    expect(listed.keys).to eq([ "Stationers" ])
    expect(listed["Stationers"].size).to eq(2)

    get routes.new_pay_run_path(account_id: account("1050").id)
    expect(listed).to eq("Cloudware" => [ euros.number_label ])
    expect(css_select("input[name='pay_run[exchange_rate]']")).not_to be_empty
    get routes.new_pay_run_path(due_by: "2026-04-01")
    expect(css_select("[data-no-bills]").first.text.squish).to eq("No AUD bills are owed that are due by 1 Apr 2026.")
  end

  it "pays the chosen bills, one payment per supplier, and emails the notices" do
    first = bill(cloudware, Date.new(2026, 4, 15), 100_00)
    second = bill(cloudware, Date.new(2026, 4, 25), 200_00)
    other = bill(stationers, Date.new(2026, 4, 18), 50_00)
    left = bill(stationers, Date.new(2026, 4, 19), 80_00)

    pay([ [ first, "100" ], [ second, "150.00" ], [ other, "" ] ])
    expect(response).to redirect_to(routes.paid_payments_path)
    expect(flash[:notice]).to eq("Paid 2 suppliers $300.00 in all. Emailing payment notices to Cloudware. Not emailed, as they have no email address: Stationers.")
    payments = TudlaAccounting::Payment.order(:id)
    expect(payments.map { |payment| [ payment.contact.name, payment.amount_cents, payment.reference, payment.account.code ] })
      .to eq([ [ "Cloudware", 250_00, "Pay run 20 Apr", "1000" ], [ "Stationers", 50_00, "Pay run 20 Apr", "1000" ] ])
    open = TudlaAccounting::Document.with_open_cents.where(id: [ first, second, other, left ].map(&:id)).to_h { |document| [ document.id, document.amount_due.cents ] }
    expect(open).to eq(first.id => 0, second.id => 50_00, other.id => 0, left.id => 80_00)
    expect(TudlaAccounting::Delivery.sole).to have_attributes(kind: "payment_notice", subject: payments.first, to: "ar@cloudware.test")
  end

  it "records nothing when a payment can't be, saying which supplier's, and keeps what was chosen" do
    first = bill(cloudware, Date.new(2026, 4, 15), 100_00)
    other = bill(stationers, Date.new(2026, 4, 18), 50_00)
    pay([ [ first, "100" ], [ other, "60" ] ], email: "0")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Stationers: $60.00 is more than is owed on #{other.number_label}")
    expect(TudlaAccounting::Payment.count).to eq(0)
    expect(css_select("input[name='pay_run[amounts][#{other.id}]']").first["value"]).to eq("60")

    pay([ [ first, "lots" ] ], paid_on: "")
    expect(response.body).to include("Give the date it is paid and lots isn&#39;t an amount (#{first.number_label})")
    pay([], exchange_rate: "x")
    expect(response.body).to include("x isn&#39;t an exchange rate")
    pay([])
    expect(response.body).to include("Choose at least one bill to pay")
    expect(css_select("input[name^='pay_run[pay]'][checked]")).to be_empty
  end

  it "pays euro bills from the euro account at the rate given" do
    euros = bill(cloudware, Date.new(2026, 4, 10), 30_00, currency: "EUR", rate: "1.6")
    pay([ [ euros, "30" ] ], account_id: account("1050").id, exchange_rate: "1.5", email: "0")
    payment = TudlaAccounting::Payment.sole
    expect(payment).to have_attributes(currency: "EUR", exchange_rate: 1.5, amount_cents: 30_00)
    expect(flash[:notice]).to eq("Paid 1 supplier EUR 30.00 in all.")
  end

  context "when allowed only to record" do
    let(:permissions) { %i[read record] }

    it "doesn't show or run a pay run" do
      get routes.new_pay_run_path
      expect(response).to have_http_status(:forbidden)
      get routes.purchase_documents_path
      expect(css_select("a[href='#{routes.new_pay_run_path}']")).to be_empty
    end
  end
end
