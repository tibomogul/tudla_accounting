require "rails_helper"

RSpec.describe "Closing periods", type: :model do
  let(:organization) { create(:organization) }
  let!(:y2026) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let!(:y2027) { TudlaAccounting::PeriodCreator.call(organization, 2027) }

  before do
    TudlaAccounting::AccountsCreator.call([ { code: "1000", name: "Cash", category: "asset" }, { code: "3100", name: "Capital", category: "equity" } ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def month(year, number) = year.children.order(:from_date)[number - 1]
  def events(action) = TudlaAccounting::AuditEvent.where(organization: organization, action: action)

  def entry_on(on)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: on)
    entry.details.build(account: account("1000"), tally: :debit, amount_cents: 100_00, currency: "USD", organization: organization)
    entry.details.build(account: account("3100"), tally: :credit, amount_cents: 100_00, currency: "USD", organization: organization)
    entry.save!
    entry
  end

  it "closes months in order, and a year with all its months" do
    expect(month(y2026, 2).close_blocker).to eq("Close the earlier periods first")
    expect { month(y2026, 2).close! }.to raise_error(ArgumentError, "Close the earlier periods first")

    month(y2026, 1).close!
    expect(month(y2026, 1)).to be_closed
    expect(month(y2026, 1).close_blocker).to eq("Jan 2026 is already closed")
    expect(month(y2026, 2).close_blocker).to be_nil

    expect(y2027.close_blocker).to eq("Close the earlier periods first")
    y2026.close!
    expect(y2026.children.where(closed_at: nil)).to be_empty
    expect(month(y2027, 1).close_blocker).to be_nil
  end

  it "reopens in reverse order, with a reason, the year before its months" do
    y2026.close!
    month(y2027, 1).close!

    expect(month(y2026, 12).reopen_blocker).to eq("Reopen the later periods first")
    expect { month(y2027, 1).reopen!(reason: " ") }.to raise_error(ArgumentError, "Give a reason for reopening Jan 2027")
    month(y2027, 1).reopen!(reason: "Late invoice")

    expect(month(y2026, 12).reopen_blocker).to eq("Reopen the year first")
    y2026.reopen!(reason: "Audit adjustment")
    expect(y2026.reload).not_to be_closed
    expect(month(y2026, 12)).to be_closed # months stay closed until reopened themselves
    expect(month(y2026, 11).reopen_blocker).to eq("Reopen the later periods first")
    month(y2026, 12).reopen!(reason: "Audit adjustment")
    expect(month(y2026, 12).reopen_blocker).to eq("Dec 2026 is not closed")
    expect(events("period.reopened").pluck(:details)).to all(include("reason"))
  end

  it "refuses to post or reverse into a closed month, but posts into the next one" do
    posted = entry_on(Time.zone.local(2026, 1, 10)).tap { |entry| entry.post(entry.transacted_at) }
    month(y2026, 1).close!

    late = entry_on(Time.zone.local(2026, 1, 20))
    expect { late.post(late.transacted_at) }.to raise_error(ArgumentError, "the period for the posted date is closed")
    expect(late.reload).to be_draft
    expect { posted.reverse!(on: Date.new(2026, 1, 31)) }.to raise_error(ArgumentError, "the period for the posted date is closed")

    posted.reverse!(on: Date.new(2026, 2, 1))
    expect(TudlaAccounting::Balance.find_by(account: account("1000"), period: month(y2026, 2)).ending_amount_cents).to eq(0)
  end

  it "refuses changes to opening balances once the first month is closed" do
    month(y2026, 1).close!
    expect {
      TudlaAccounting::StartingBalanceCreator.call(organization, Date.new(2026, 1, 1), [ { account_id: account("1000").id, amount_cents: 1 } ], "USD")
    }.to raise_error(ArgumentError, "Jan 2026 is closed; reopen it to change the opening balances")
  end

  it "is enforced by the database too" do
    month(y2026, 1).close!
    entry = entry_on(Time.zone.local(2026, 1, 20))

    expect { entry.update_columns(posted_at: entry.transacted_at) }
      .to raise_error(ActiveRecord::StatementInvalid, /Entry #{entry.id} falls in a closed period and cannot be posted/)
  end

  it "records who closed and reopened periods" do
    TudlaAccounting::Current.set(actor: "Jo Bookkeeper") do
      month(y2026, 1).close!
      month(y2026, 1).reopen!(reason: "Missed receipt")
    end

    expect(TudlaAccounting::AuditEvent.where(organization: organization, action: %w[period.closed period.reopened]).order(:id)
      .pluck(:action, :actor_label, :subject_label, :details))
      .to eq([ [ "period.closed", "Jo Bookkeeper", "Jan 2026", {} ], [ "period.reopened", "Jo Bookkeeper", "Jan 2026", { "reason" => "Missed receipt" } ] ])
  end

  it "labels periods that are neither calendar years nor months by their dates" do
    fiscal = TudlaAccounting::PeriodCreator.call(create(:organization), 2026, 7)
    expect(fiscal.label).to eq("1 Jul 2026 – 30 Jun 2027")
  end
end
