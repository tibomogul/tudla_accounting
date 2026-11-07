require "rails_helper"
require Rails.root.join("../../db/migrate/20261108210000_add_kind_to_tudla_accounting_entries").to_s

# Exchange differences and revaluations posted before entries had a kind were known only
# by their particulars: the migration marks them.
RSpec.describe AddKindToTudlaAccountingEntries do
  let(:organization) { create(:organization, currency: "USD") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1000", name: "Cash", category: "asset" }, { code: "3000", name: "Capital", category: "equity" } ], organization)
  end

  after { TudlaAccounting::Entry.reset_column_information }

  def posted(particulars, related: nil, source: nil)
    on = Time.zone.local(2026, 2, 1)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: particulars, transacted_at: on, related: related, source: source)
    entry.details.build(account: TudlaAccounting::Account.find_by!(organization: organization, code: "1000"), tally: :debit, amount_cents: 1_00, currency: "USD", organization: organization)
    entry.details.build(account: TudlaAccounting::Account.find_by!(organization: organization, code: "3000"), tally: :credit, amount_cents: 1_00, currency: "USD", organization: organization)
    entry.save!
    entry.post(on)
    entry
  end

  it "marks the engine's exchange differences and revaluations by their particulars, and nothing else" do
    original = posted("Payment")
    entries = [ posted("Realized exchange gain on Invoice 1", related: original), posted("Revaluation of Debtors - EUR", related: original),
                posted("Reversal of Revaluation of Debtors - EUR", related: original), posted("Realized exchange gain, typed by hand"),
                posted("Revaluation of Debtors - EUR", related: original, source: original) ]

    ActiveRecord::Migration.suppress_messages do
      described_class.new.migrate(:down)
      TudlaAccounting::Entry.reset_column_information
      described_class.new.migrate(:up)
    end
    TudlaAccounting::Entry.reset_column_information

    expect(TudlaAccounting::Entry.where(id: entries.map(&:id)).order(:id).pluck(:kind)).to eq([ "realized_exchange", "revaluation", "revaluation_reversal", nil, nil ])
    expect(TudlaAccounting::Entry.find(entries.first.id)).to be_realized_exchange
  end
end
