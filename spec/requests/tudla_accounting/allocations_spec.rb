require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/entry_sources"

RSpec.describe "Applying payments", type: :request do
  include_context "with entry source models"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:globex) { create(:organization, name: "Globex") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    sign_in_as(organization)
    TudlaAccounting.configuration.related_party_method = :customer
    TudlaAccounting.configuration.realized_fx_gain_account_code = "4950"
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash", category: "asset" },
      { code: "1100", name: "Accounts Receivable", category: "asset", children: [
        { code: "1100-EUR", name: "Accounts Receivable - EUR", category: "asset", currency: "EUR" } ] },
      { code: "4000", name: "Sales", category: "income" },
      { code: "4950", name: "Realized FX Gain", category: "income" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def on(month, day) = Time.zone.local(2026, month, day)
  def open_item(entry) = TudlaAccounting::Allocator.carrying_amount(entry.reload).reload
  def rows = css_select("section[aria-labelledby=allocations-heading] tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
  def total(name) = css_select("[data-total=#{name}]").first.text.squish

  def post_entry(lines, at:, particulars:, **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: particulars, transacted_at: at, **attrs)
    lines.each do |code, tally, cents, fx|
      line = entry.details.build(account: account(code), tally: tally, amount_cents: cents, currency: "AUD", organization: organization)
      line.build_foreign_exchange(other_currency: "EUR", other_currency_cents: fx[0], rate: BigDecimal(fx[1])) if fx
    end
    entry.save!
    entry.post(at)
    entry
  end

  def invoice(name, cents, due:) = post_entry([ [ "1100", :debit, cents ], [ "4000", :credit, cents ] ], at: on(3, 1), particulars: name,
                                              source: Invoice.create!(due_date: due, customer: globex))

  let!(:inv1) { invoice("Invoice 1", 300_00, due: on(3, 31)) }
  let!(:inv2) { invoice("Invoice 2", 200_00, due: on(3, 15)) }
  let!(:pay) { post_entry([ [ "1000", :debit, 450_00 ], [ "1100", :credit, 450_00 ] ], at: on(3, 20), particulars: "Payment 1", source: Payment.create!(customer: globex)) }

  it "shows a payment's credit and the invoices it could go to, oldest due first" do
    get routes.entry_path(pay)

    expect(total("left_to_apply")).to eq("Left to apply: 450.00")
    expect(response.body).to include("Nothing applied yet.")
    expect(css_select("#to_id option").map(&:text)).to eq([ "Invoice 2 · owes 200.00 · due 15 Mar 2026", "Invoice 1 · owes 300.00 · due 31 Mar 2026" ])
  end

  it "applies part of it to a chosen invoice, then the rest oldest first, and takes one off" do
    post routes.allocations_path, params: { entry_id: pay.id, to_id: open_item(inv1).id, amount: "120", on: "2026-03-21" }
    expect(response).to redirect_to(routes.entry_path(pay))
    expect(flash[:notice]).to eq("Applied 120.00 to Invoice 1.")

    post routes.oldest_first_allocations_path, params: { entry_id: pay.id, on: "2026-03-22" }
    expect(flash[:notice]).to eq("Applied to Invoice 2 and Invoice 1.")
    expect([ open_item(inv1).amount_cents, open_item(inv2).amount_cents, open_item(pay).amount_cents ]).to eq([ 50_00, 0, 0 ])

    get routes.entry_path(pay)
    expect(rows).to eq([ [ "Invoice 1", "21 Mar 2026", "120.00", "Take off" ], [ "Invoice 2", "22 Mar 2026", "200.00", "Take off" ],
                         [ "Invoice 1", "22 Mar 2026", "130.00", "Take off" ] ])
    expect(css_select("#to_id")).to be_empty # nothing left to apply

    first = TudlaAccounting::Allocation.order(:id).first
    post routes.reverse_allocation_path(first), params: { on: "2026-03-23" }
    expect(flash[:notice]).to eq("Took 120.00 off Invoice 1.")
    get routes.entry_path(pay)
    expect(rows.first).to eq([ "Invoice 1", "21 Mar 2026", "120.00", "Taken off 23 Mar 2026" ])
    expect(total("left_to_apply")).to eq("Left to apply: 120.00")

    post routes.reverse_allocation_path(first)
    expect(flash[:alert]).to eq("It was not taken off: this allocation has already been taken off.")

    get routes.entry_path(inv1)
    expect(total("still_owed")).to eq("Still owed: 170.00")
    expect(rows.map(&:first)).to eq([ "Payment 1", "Payment 1" ])

    get routes.activity_path(kind: "allocation")
    expect(css_select("tbody tr td:last-child").map { |cell| cell.text.squish }.first(2))
      .to eq([ "Took off Payment 1 to Invoice 1", "Applied Payment 1 to Invoice 1" ])
    expect(css_select("tbody tr a").first["href"]).to eq(routes.entry_path(pay))
  end

  it "explains what it can't apply" do
    post routes.allocations_path, params: { entry_id: pay.id, to_id: open_item(inv1).id, amount: "301" }
    expect(flash[:alert]).to eq("Nothing was applied: that is more than is owed.")

    post routes.allocations_path, params: { entry_id: pay.id, to_id: open_item(inv1).id, amount: "lots" }
    expect(flash[:alert]).to eq("Nothing was applied: lots isn't an amount.")

    post routes.allocations_path, params: { entry_id: pay.id, to_id: 0 }
    expect(flash[:alert]).to eq("Nothing was applied: choose an invoice or bill that is still owed.")

    post routes.oldest_first_allocations_path, params: { entry_id: inv1.id }
    expect(flash[:alert]).to eq("Nothing was applied: only a payment or credit note can be applied.")

    year.children.order(:from_date).first(3).each(&:close!)
    post routes.reverse_allocation_path(TudlaAccounting::Allocator.allocate!(pay, inv1, at: on(4, 1))), params: { on: "2026-03-30" }
    expect(flash[:alert]).to eq("It was not taken off: mar 2026 is closed.")
  end

  it "says when nothing is owed that it could go to" do
    late = post_entry([ [ "1000", :debit, 5_00 ], [ "1100", :credit, 5_00 ] ], at: on(3, 22), particulars: "Payment 2",
                      source: Payment.create!(customer: create(:organization, name: "Initech"))) # owes nothing

    get routes.entry_path(late)
    expect(response.body).to include("Nothing is owed that it could be applied to.")
    post routes.oldest_first_allocations_path, params: { entry_id: late.id }
    expect(flash[:notice]).to eq("Nothing is owed that it could be applied to.")
  end

  it "takes a foreign amount in the foreign currency" do
    eur_inv = post_entry([ [ "1100-EUR", :debit, 154_00, [ 100_00, "1.54" ] ], [ "4000", :credit, 154_00 ] ], at: on(3, 1), particulars: "Invoice EUR",
                         source: Invoice.create!(customer: globex))
    eur_pay = post_entry([ [ "1000", :debit, 160_00 ], [ "1100-EUR", :credit, 160_00, [ 100_00, "1.60" ] ] ], at: on(3, 10), particulars: "Payment EUR",
                         source: Payment.create!(customer: globex))

    get routes.entry_path(eur_pay)
    expect(css_select("label[for=amount]").text).to eq("Amount (EUR for EUR invoices)")
    expect(total("left_to_apply")).to eq("Left to apply: 160.00 (€100,00)")

    post routes.allocations_path, params: { entry_id: eur_pay.id, to_id: open_item(eur_inv).id, amount: "60", on: "2026-03-12" }
    expect(TudlaAccounting::Allocation.last).to have_attributes(amount_cents: 96_00, other_currency_cents: 60_00)
    get routes.entry_path(eur_pay)
    expect(rows).to eq([ [ "Invoice EUR", "12 Mar 2026", "96.00 (€60,00)", "Take off" ] ])
  end

  it "refuses another organization's allocation" do
    other = create(:organization)
    sign_in_as(other)
    post routes.reverse_allocation_path(TudlaAccounting::Allocator.allocate!(pay, inv1, at: on(3, 21)))
    expect(response).to have_http_status(:not_found)
  end
end
