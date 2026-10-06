require "rails_helper"

RSpec.describe TudlaAccounting::AuditEvent, type: :model do
  let(:organization) { create(:organization, name: "Acme") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting::AccountsCreator.call([ { code: "1000", name: "Cash", category: "asset" }, { code: "3100", name: "Capital", category: "equity" } ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def actions = described_class.where(organization: organization).order(:id).pluck(:action)
  def last_event = described_class.where(organization: organization).order(:id).last

  def draft
    entry = build(:tudla_accounting_entry, organization: organization, particulars: "Capital in", transacted_at: Time.zone.local(2026, 3, 1))
    entry.details.build(account: account("1000"), tally: :debit, amount_cents: 100_00, currency: "USD", organization: organization)
    entry.details.build(account: account("3100"), tally: :credit, amount_cents: 100_00, currency: "USD", organization: organization)
    entry.save!
    entry
  end

  it "records the year and accounts being set up" do
    expect(actions).to eq(%w[period.created account.created account.created])
    expect(described_class.where(organization: organization).first).to have_attributes(subject: year, subject_label: "2026", actor: nil, actor_label: nil)
  end

  it "records posting, reversing and deleting drafts" do
    entry = draft
    entry.post(entry.transacted_at)
    expect(last_event).to have_attributes(action: "entry.posted", subject: entry, subject_label: "Capital in", details: { "posted_at" => "2026-03-01T00:00:00Z" })

    reversal = entry.reverse!(on: Date.new(2026, 3, 5))
    expect(described_class.where(action: "entry.reversed").sole).to have_attributes(subject: entry, details: { "reversal_id" => reversal.id, "on" => "2026-03-05" })

    unwanted = draft
    unwanted.destroy!
    expect(last_event).to have_attributes(action: "entry.deleted", subject_id: unwanted.id, subject_label: "Capital in")
  end

  it "records account changes, but not saves that change nothing" do
    account("1000").update!(name: "Cash at bank")
    expect(last_event).to have_attributes(action: "account.updated", subject_label: "1000 - Cash at bank", details: { "changes" => { "name" => [ "Cash", "Cash at bank" ] } })

    expect { account("1000").save! }.not_to change(described_class, :count)
    account("3100").destroy!
    expect(last_event).to have_attributes(action: "account.deleted", subject_label: "3100 - Capital")
  end

  it "records opening balances, rebuilds and deleted years" do
    TudlaAccounting::StartingBalanceCreator.call(organization, Date.new(2026, 1, 1), [ { account_id: account("1000").id, amount_cents: 5_00 } ], "USD")
    expect(last_event).to have_attributes(action: "opening_balances.saved", details: { "date" => "2026-01-01", "overwrite" => false })

    TudlaAccounting::BalanceRebuilder.new(organization).rebuild!
    expect(last_event).to have_attributes(action: "balances.rebuilt", details: { "corrected" => 0 })

    spare = TudlaAccounting::PeriodCreator.call(organization, 2030)
    spare.destroy_with_subtree!
    expect(last_event).to have_attributes(action: "period.deleted", subject_label: "2030")
  end

  it "names the actor: a label, or a record by its name, its email, or its type and id" do
    with_name = create(:organization, name: "Jo")
    with_email = Struct.new(:id, :name, :email).new(7, nil, "jo@example.com")
    nameless = stub_const("Robot", Struct.new(:id)).new(9)

    TudlaAccounting::Current.set(actor: with_name) { account("1000").update!(name: "A") }
    expect(last_event).to have_attributes(actor: with_name, actor_label: "Jo")
    expect(described_class.label_for(with_email)).to eq("jo@example.com")
    expect(described_class.label_for(nameless)).to eq("Robot #9")
    TudlaAccounting::Current.set(actor: "Script") { account("1000").update!(name: "B") }
    expect(last_event).to have_attributes(actor_type: nil, actor_label: "Script")
  end

  it "can't be changed or deleted" do
    event = last_event
    expect(event).to be_readonly
    attempt = ->(&change) { ActiveRecord::Base.transaction(requires_new: true, &change) }
    expect { attempt.call { described_class.where(id: event.id).update_all(action: "entry.posted") } }
      .to raise_error(ActiveRecord::StatementInvalid, /Audit events \(id #{event.id}\) cannot be changed or deleted/)
    expect { attempt.call { described_class.where(id: event.id).delete_all } }.to raise_error(ActiveRecord::StatementInvalid, /cannot be changed or deleted/)
  end

  it "only takes known actions" do
    expect { described_class.record!("entry.edited", organization: organization) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
