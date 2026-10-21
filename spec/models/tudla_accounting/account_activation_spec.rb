require "rails_helper"

RSpec.describe "Inactive accounts" do
  let(:organization) { create(:organization, currency: "USD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash", category: "asset", children: [
        { code: "1010", name: "Old bank", category: "asset", children: [ { code: "1011", name: "Old bank, USD", category: "asset" } ] },
        { code: "1020", name: "New bank", category: "asset" } ] },
      { code: "1100", name: "Receivables", category: "asset", role: "receivable", children: [ { code: "1105", name: "Receivables, EUR", category: "asset" } ] },
      { code: "2200", name: "GST", category: "liability" },
      { code: "3000", name: "Capital", category: "equity" },
      { code: "6000", name: "Printing", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def events(action) = TudlaAccounting::AuditEvent.where(organization: organization, action: action)

  def entry(debit, credit, posted: false)
    record = build(:tudla_accounting_entry, organization: organization, particulars: "Capital", transacted_at: Time.zone.local(2026, 2, 1))
    record.details.build(account: account(debit), tally: :debit, amount_cents: 100_00, currency: "USD")
    record.details.build(account: account(credit), tally: :credit, amount_cents: 100_00, currency: "USD")
    record.save!
    record.post(record.transacted_at) if posted
    record
  end

  def entry_hash(code)
    { organization_type: "Organization", organization_id: organization.id, particulars: "Printing", transacted_at: "2026-02-01T00:00:00Z",
      details: [ { account_code: code, amount: "USD 10.00" }, { account_code: "1020", amount: "USD -10.00" } ] }
  end

  it "makes an account and those beneath it inactive, keeping their history, on the audit trail" do
    entry("1011", "3000", posted: true)
    expect { account("1010").deactivate! }.not_to change(events("account.updated"), :count) # recorded as one event of its own

    expect(%w[1010 1011].map { |code| account(code).active? }).to eq([ false, false ])
    expect(account("1000")).to be_active
    expect(TudlaAccounting::Balance.peek(account("1011"), year).ending_amount_cents).to eq(100_00)
    expect(events("account.deactivated").sole).to have_attributes(subject: account("1010"), details: { "sub_accounts" => [ "1011" ] })
    expect { account("1010").deactivate! }.to raise_error(ArgumentError, "1010 - Old bank is inactive already")
  end

  it "reactivates an account on its own, once its parent is active" do
    account("1010").deactivate!
    expect { account("1011").reactivate! }.to raise_error(ArgumentError, "Reactivate 1010 - Old bank first")

    account("1010").reactivate!
    expect([ account("1010").active?, account("1011").active? ]).to eq([ true, false ])
    account("1011").reactivate!
    expect(account("1011")).to be_active
    expect(events("account.reactivated").count).to eq(2)
    expect { account("1011").reactivate! }.to raise_error(ArgumentError, "1011 - Old bank, USD is active already")
  end

  it "keeps an account that holds a role, takes an active tax code's tax, or has open items" do
    expect(account("1100").deactivation_blocker).to eq("1100 - Receivables is the Receivables account; move the role to another account first")

    TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200"))
    expect { account("2200").deactivate! }
      .to raise_error(ArgumentError, "2200 - GST is where the GST tax code posts; change its account or make it inactive first")

    invoice = entry("1105", "3000")
    create(:tudla_accounting_carrying_amount, detail: invoice.details.find(&:debit?), amount_cents: 100_00)
    expect(account("1105").deactivation_blocker).to eq("1105 - Receivables, EUR has receivables or payables still open")
    expect(account("1105")).to be_active
  end

  it "checks a sub-account's blockers too" do
    TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("1011"))
    expect { account("1010").deactivate! }.to raise_error(ArgumentError, /\A1011 - Old bank, USD is where the GST tax code posts/)
    expect(account("1010")).to be_active
  end

  it "refuses saves that would leave an active account under an inactive one, or a role or tax on an inactive one" do
    parent = account("1010")
    expect(parent.update(active: false)).to be(false)
    expect(parent.errors[:base]).to eq([ "1010 - Old bank has active sub-accounts" ])

    account("1010").deactivate!
    child = TudlaAccounting::Account.new(organization: organization, code: "1012", name: "Old bank, EUR", category: "asset", parent: account("1010"))
    expect(child.save).to be(false)
    expect(child.errors[:base]).to eq([ "1010 - Old bank is inactive; reactivate it first" ])

    expect(TudlaAccounting::AccountRoleAssigner.save(account("1011"), "receivable")).to be(false)
    tax = TudlaAccounting::TaxCode.new(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("1011"))
    expect(tax.save).to be(false)
    expect(tax.errors[:account]).to eq([ "is inactive" ])
  end

  it "takes no new entries from create_from_ruby_hash or the bank reconciler, but posts drafts already written" do
    draft = entry("6000", "1020")
    account("6000").deactivate!

    expect { TudlaAccounting::Entry.create_from_ruby_hash(entry_hash("6000")) }.to raise_error(ArgumentError, "account 6000 is inactive")
    expect(TudlaAccounting::Entry.create_from_ruby_hash(entry_hash("1011"))).to be_persisted
    expect(draft.post(draft.transacted_at)).to be(true)

    line = TudlaAccounting::BankStatementLine.create!(organization: organization, account: account("1020"), occurred_on: Date.new(2026, 2, 3),
                                                      description: "Print shop", amount_cents: -10_00, currency: "USD", external_id: "p1")
    expect { TudlaAccounting::BankReconciler.new(account("1020")).create_entry!(line, account: account("6000")) }
      .to raise_error(ArgumentError, "6000 - Printing is inactive")
  end
end
