require "rails_helper"

RSpec.describe "Line descriptions" do
  let(:organization) { create(:organization, currency: "USD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let!(:cash) { create(:tudla_accounting_account, code: "1000", category: :asset, organization: organization) }
  let!(:capital) { create(:tudla_accounting_account, code: "3000", category: :equity, organization: organization) }

  def entry_from(details)
    TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Capital",
                                                 transacted_at: "2026-02-01T00:00:00Z", details: details)
  end

  it "takes each line's description from create_from_ruby_hash, and keeps them on the reversal" do
    entry = entry_from([ { account_code: "1000", amount: "USD 10.00", description: " Cheque 1001 " }, { account_code: "3000", amount: "USD 10.00" } ])
    expect(entry.details.map { |line| [ line.account.code, line.description ] }).to contain_exactly([ "1000", "Cheque 1001" ], [ "3000", nil ])

    entry.post(entry.transacted_at)
    reversal = entry.reverse!(on: Date.new(2026, 2, 5))
    expect(reversal.details.map { |line| [ line.account.code, line.description ] }).to contain_exactly([ "1000", "Cheque 1001" ], [ "3000", nil ])
  end

  it "refuses a description that isn't a string, or is too long" do
    expect { entry_from([ { account_code: "1000", amount: "USD 10.00", description: 7 }, { account_code: "3000", amount: "USD 10.00" } ]) }
      .to raise_error(ArgumentError, "description must be a string")
    expect { entry_from([ { account_code: "1000", amount: "USD 10.00", description: "x" * 256 }, { account_code: "3000", amount: "USD 10.00" } ]) }
      .to raise_error(ActiveRecord::RecordInvalid, /Details description is too long/)
  end

  it "is fixed once the entry is posted" do
    entry = entry_from([ { account_code: "1000", amount: "USD 10.00" }, { account_code: "3000", amount: "USD 10.00" } ])
    entry.post(entry.transacted_at)
    expect { TudlaAccounting::Entry.transaction(requires_new: true) { entry.details.first.update_columns(description: "Changed") } }
      .to raise_error(ActiveRecord::StatementInvalid, /cannot be changed/)
  end

  it "shows in the general ledger's CSV" do
    entry = entry_from([ { account_code: "1000", amount: "USD 10.00", description: "Cheque 1001" }, { account_code: "3000", amount: "USD 10.00" } ])
    entry.post(entry.transacted_at)
    february = year.children.order(:from_date).second
    csv = CSV.parse(TudlaAccounting::Reports::GeneralLedger.new(organization, from: february, thru: february, account_ids: [ cash.id ]).to_csv, headers: true)
    expect(csv.map { |row| row.values_at("Entry", "Description") }).to eq([ [ "Opening balance", nil ], [ "Capital", "Cheque 1001" ], [ "Closing balance", nil ] ])
  end
end
