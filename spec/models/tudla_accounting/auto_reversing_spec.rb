require "rails_helper"
require_relative "../../support/entry_sources"

RSpec.describe "Auto-reversing entries" do
  let(:organization) { create(:organization, currency: "USD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash", category: "asset" }, { code: "1100", name: "Receivables", category: "asset" },
      { code: "2300", name: "Accrued expenses", category: "liability" }, { code: "4000", name: "Sales", category: "income" },
      { code: "6200", name: "Electricity", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def month(number) = year.children.order(:from_date).to_a[number - 1]
  def balance(code, period) = TudlaAccounting::Balance.peek(account(code), period).ending_amount_cents

  def accrual(reverse_on: Date.new(2026, 4, 1), **attrs)
    TudlaAccounting::Entry.create_from_ruby_hash(
      organization_type: "Organization", organization_id: organization.id, particulars: "March electricity, not yet billed",
      transacted_at: "2026-03-31T00:00:00Z", reverse_on: reverse_on&.iso8601,
      details: [ { account_code: "6200", amount: "USD 120.00" }, { account_code: "2300", amount: "USD 120.00" } ], **attrs
    )
  end

  it "posts its reversal on the day given, with it" do
    entry = accrual
    expect(entry.reverse_on).to eq(Date.new(2026, 4, 1))
    entry.post(entry.transacted_at)

    reversal = entry.reversal
    expect(reversal).to have_attributes(related: entry, particulars: "Reversal of: March electricity, not yet billed", number: 2,
                                        posted_at: Time.zone.local(2026, 4, 1), reverse_on: nil)
    expect([ balance("2300", month(3)), balance("2300", month(4)) ]).to eq([ 120_00, 0 ])
    expect(TudlaAccounting::AuditEvent.where(organization: organization).pluck(:action).last(3)).to eq(%w[entry.posted entry.posted entry.reversed])
  end

  it "posts neither when the reversal date can't take it" do
    entry = accrual(reverse_on: Date.new(2027, 1, 1))
    expect { entry.post(entry.transacted_at) }.to raise_error(ArgumentError, "no financial year covers the reversal date")
    expect(entry.reload).to be_draft
    expect(balance("2300", month(3))).to eq(0)
  end

  it "needs a reversal date after the entry's own, given as an ISO date" do
    expect { accrual(reverse_on: Date.new(2026, 3, 31)) }.to raise_error(ActiveRecord::RecordInvalid, /Reverse on must be after the entry's date/)
    expect(accrual(reverse_on: nil).reverse_on).to be_nil
    expect { TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "x",
                                                          transacted_at: "2026-03-31T00:00:00Z", reverse_on: "next week", details: []) }
      .to raise_error(ArgumentError, "reverse_on must be a valid ISO 8601 date string")
  end

  context "with entry source models" do
    include_context "with entry source models"

    it "refuses it on an invoice, whose reversal would close its receivable" do
      TudlaAccounting::AccountRoleAssigner.save!(account("1100"), "receivable")
      invoice = Invoice.create!
      expect {
        TudlaAccounting::Entry.create_from_ruby_hash(
          organization_type: "Organization", organization_id: organization.id, particulars: "Invoice", transacted_at: "2026-03-31T00:00:00Z",
          reverse_on: "2026-04-01", source_type: "Invoice", source_id: invoice.id,
          details: [ { account_code: "1100-USD", amount: "USD 10.00" }, { account_code: "4000", amount: "USD 10.00" } ]
        )
      }.to raise_error(ActiveRecord::RecordInvalid, /can't be set on an invoice, bill, payment or credit/)
    end
  end
end
