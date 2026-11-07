require "rails_helper"
require Rails.root.join("../../db/migrate/20261108200000_add_reversal_of_to_tudla_accounting_entries").to_s

# Reversals made before reversal_of_id were known only by their "Reversal of: " particulars
# and the entry they're related to: the migration links them.
RSpec.describe AddReversalOfToTudlaAccountingEntries do
  let(:organization) { create(:organization, currency: "USD") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1000", name: "Cash", category: "asset" }, { code: "3000", name: "Capital", category: "equity" } ], organization)
  end

  after { TudlaAccounting::Entry.reset_column_information }

  def posted(particulars, on, related: nil)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: particulars, transacted_at: on, related: related)
    entry.details.build(account: TudlaAccounting::Account.find_by!(organization: organization, code: "1000"), tally: :debit, amount_cents: 100_00, currency: "USD", organization: organization)
    entry.details.build(account: TudlaAccounting::Account.find_by!(organization: organization, code: "3000"), tally: :credit, amount_cents: 100_00, currency: "USD", organization: organization)
    entry.save!
    entry.post(on)
    entry
  end

  it "links each old reversal to the entry it reverses, leaving lookalikes and drafts alone" do
    original = posted("Capital", Time.zone.local(2026, 2, 1))
    reversal = original.reverse!(on: Date.new(2026, 3, 1))
    other = posted("Capital", Time.zone.local(2026, 2, 2))
    lookalike = posted("Reverse of: Capital", Time.zone.local(2026, 3, 2), related: other)
    draft = build(:tudla_accounting_entry, organization: organization, particulars: "Reversal of: Capital", related: other).tap { |entry| entry.save!(validate: false) }

    ActiveRecord::Migration.suppress_messages do
      described_class.new.migrate(:down)
      TudlaAccounting::Entry.reset_column_information
      described_class.new.migrate(:up)
    end
    TudlaAccounting::Entry.reset_column_information

    expect(TudlaAccounting::Entry.where(id: [ reversal, lookalike, draft ].map(&:id)).order(:id).pluck(:reversal_of_id)).to eq([ original.id, nil, nil ])
    expect(original.reload.reversal).to eq(reversal)
  end
end
