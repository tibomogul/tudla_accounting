require "rails_helper"
require_relative "../../support/entry_sources"

# Payments posted before allocations existed settled their invoice directly: no credit,
# no allocation, and the invoice's stored amount reduced by the whole payment.
RSpec.describe TudlaAccounting::AllocationBackfill, type: :service do
  include_context "with entry source models"

  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
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

  def post(lines, at:, particulars:, **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: particulars, transacted_at: at, **attrs)
    lines.each do |code, tally, cents, fx|
      line = entry.details.build(account: account(code), tally: tally, amount_cents: cents, currency: "AUD", organization: organization)
      line.build_foreign_exchange(other_currency: "EUR", other_currency_cents: fx[0], rate: BigDecimal(fx[1])) if fx
    end
    entry.save!
    entry.post(at)
    entry
  end

  def payment(name, cents, at:, related: nil)
    post([ [ "1000", :debit, cents ], [ "1100", :credit, cents ] ], at: at, particulars: name, source: Payment.create!, related: related)
  end

  # Back to how the books looked before allocations: no credits or allocations, and each
  # invoice's stored amount reduced by every payment against it that still stands.
  def as_before_allocations(stored)
    TudlaAccounting::Allocation.delete_all
    credits = TudlaAccounting::CarryingAmount.all.select(&:credit?)
    TudlaAccounting::CarryingAmountForex.where(carrying_amount: credits).delete_all
    TudlaAccounting::CarryingAmount.where(id: credits.map(&:id)).delete_all
    stored.each { |entry, cents| open_item(entry).update!(amount_cents: cents) }
  end

  it "gives each payment its credit, applied to its invoice as far as that was owed" do
    inv = post([ [ "1100", :debit, 300_00 ], [ "4000", :credit, 300_00 ] ], at: on(3, 1), particulars: "Invoice 1", source: Invoice.create!)
    bounced = payment("Bounced", 50_00, at: on(3, 4), related: inv)
    part = payment("Part", 100_00, at: on(3, 5), related: inv)
    overpaid = payment("Overpaid", 250_00, at: on(3, 6), related: inv)
    on_account = payment("On account", 40_00, at: on(3, 7))
    bounced.reload.reverse!(on: Date.new(2026, 3, 10))
    eur = post([ [ "1100-EUR", :debit, 154_00, [ 100_00, "1.54" ] ], [ "4000", :credit, 154_00 ] ], at: on(3, 1), particulars: "Invoice EUR", source: Invoice.create!)
    eur_paid = post([ [ "1000", :debit, 160_00 ], [ "1100-EUR", :credit, 160_00, [ 100_00, "1.60" ] ] ], at: on(3, 12), particulars: "Paid EUR",
                    source: Payment.create!, related: eur)
    realized = TudlaAccounting::Entry.find_by(related: eur_paid)
    as_before_allocations(inv => -50_00, eur => 0)

    expect { expect(described_class.call).to eq(5) }.not_to change(TudlaAccounting::AuditEvent, :count) # nothing new happened

    expect(TudlaAccounting::Allocation.order(:allocated_at, :id).map { |a| [ a.from.detail.entry.particulars, a.amount_cents, a.other_currency_cents, a.reversed_at, a.realized_entry ] })
      .to eq([ [ "Bounced", 50_00, nil, on(3, 10), nil ], [ "Part", 100_00, nil, nil, nil ], [ "Overpaid", 200_00, nil, nil, nil ],
               [ "Paid EUR", 160_00, 100_00, nil, realized ] ])
    expect([ inv, bounced, part, overpaid, on_account, eur, eur_paid ].map { |entry| open_item(entry).amount_cents })
      .to eq([ 0, 0, 0, -50_00, -40_00, 0, 0 ])
    expect(described_class.call).to eq(0) # already converted
  end

  it "does nothing until roles are configured" do
    TudlaAccounting.configuration.carrying_amount_sources = {}
    expect(described_class.call).to eq(0)
  end
end
