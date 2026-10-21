require "rails_helper"

RSpec.describe TudlaAccounting::Budget do
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:last_year) { TudlaAccounting::PeriodCreator.call(organization, 2025) }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" },
      { code: "4000", name: "Sales", category: "income", children: [
        { code: "4010", name: "Products", category: "income" }, { code: "4020", name: "Services", category: "income" }
      ] },
      { code: "4900", name: "Sales returns", category: "income", contra_account: "4000" },
      { code: "6100", name: "Rent", category: "expense" }, { code: "6200", name: "Software", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def month(period, number) = period.children.order(:from_date).to_a[number - 1]
  def budget(**attrs) = described_class.create!({ organization: organization, period: year, name: "Original" }.merge(attrs))

  def post(on, details)
    entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Entry",
                                                         transacted_at: on.iso8601, details: details)
    entry.post(entry.transacted_at)
  end

  describe "#set_amounts!" do
    it "keeps the accounts' amounts given, leaving out zeros and the other accounts, on the audit trail" do
      plan = budget
      expect(plan.set_amounts!(account("6100").id => { month(year, 1).id => 1_000_00, month(year, 2).id => 0 }, account("4010").id => { month(year, 1).id => 5_000_00 })).to be(true)
      expect(plan.amounts).to eq(account("6100").id => { month(year, 1).id => 1_000_00 }, account("4010").id => { month(year, 1).id => 5_000_00 })

      expect(plan.set_amounts!(account("6100").id.to_s => { month(year, 3).id.to_s => "1200" })).to be(true)
      expect(plan.amounts).to eq(account("6100").id => { month(year, 3).id => 1200 }, account("4010").id => { month(year, 1).id => 5_000_00 })
      expect(plan.set_amounts!(account("6100").id => { month(year, 3).id => 1200 })).to be(false)

      expect(TudlaAccounting::AuditEvent.where(organization: organization, action: "budget.updated").pluck(:details)).to eq([ { "accounts" => %w[4010 6100] }, { "accounts" => %w[6100] } ])
    end

    it "refuses other accounts, inactive ones new to it, and months of other years" do
      plan = budget
      expect { plan.set_amounts!(account("1000").id => { month(year, 1).id => 1 }) }.to raise_error(ArgumentError, "Only the organization's income and expense accounts can have a budget")
      expect { plan.set_amounts!(account("6100").id => { month(last_year, 1).id => 1 }) }.to raise_error(ArgumentError, "The amounts must be for months of 2026")

      plan.set_amounts!(account("6100").id => { month(year, 1).id => 1 })
      account("6100").deactivate!
      account("6200").deactivate!
      expect { plan.set_amounts!(account("6200").id => { month(year, 1).id => 1 }) }.to raise_error(ArgumentError, "6200 - Software is inactive")
      expect(plan.set_amounts!(account("6100").id => { month(year, 1).id => 2 }, account("6200").id => {})).to be(true)
    end
  end

  it "is for one of the organization's years, named uniquely, with one main budget a year" do
    first = budget(main: true)
    second = budget(name: "Revised", main: true)
    expect(first.reload).not_to be_main
    expect(second).to be_main
    expect(described_class.new(organization: organization, period: year, name: " Original ")).not_to be_valid
    monthly = described_class.new(organization: organization, period: month(year, 1), name: "x")
    expect(monthly).not_to be_valid
    expect(monthly.errors[:period]).to eq([ "must be one of the organization's years" ])
    expect(first.label).to eq("Original (2026)")
  end

  describe "#fill_from_actuals!" do
    it "takes each month's actual results, changed and rounded, what the parent had directly, and no inactive accounts" do
      post(Time.zone.local(2025, 1, 10), [ { account_code: "4010", amount: "AUD 1000.00" }, { account_code: "4000", amount: "AUD 200.00" },
                                           { account_code: "6200", amount: "AUD 50.40" }, { account_code: "1000", amount: "AUD 1149.60" } ])
      post(Time.zone.local(2025, 3, 10), [ { account_code: "6100", amount: "AUD 100.00" }, { account_code: "1000", amount: "AUD -100.00" } ])
      account("6200").deactivate!

      plan = budget
      plan.fill_from_actuals!(last_year, percent: 10)
      expect(plan.amounts).to eq(account("4010").id => { month(year, 1).id => 1_100_00 }, account("4000").id => { month(year, 1).id => 220_00 },
                                 account("6100").id => { month(year, 3).id => 110_00 })
    end
  end

  it "copies another budget month for month" do
    original = budget
    original.set_amounts!(account("6100").id => { month(year, 2).id => 300_00 })
    copy = described_class.create!(organization: organization, period: last_year, name: "Copy")
    copy.fill_from_budget!(original)
    expect(copy.amounts).to eq(account("6100").id => { month(last_year, 2).id => 300_00 })
  end

  it "keeps its accounts from being deleted or changing category, and its year from being deleted" do
    budget.set_amounts!(account("6200").id => { month(year, 1).id => 1 })
    expect(account("6200")).not_to be_deletable
    software = account("6200")
    expect(software.update(category: "asset")).to be(false)
    expect(software.errors[:category]).to eq([ "can't change while a budget has amounts for the account" ])
    expect(year).not_to be_deletable
    expect(TudlaAccounting::Period.roots.find(last_year.id)).to be_deletable
  end

  it "is on the audit trail" do
    plan = budget
    plan.update!(main: true)
    plan.destroy!
    expect(TudlaAccounting::AuditEvent.where(organization: organization).where("action LIKE 'budget%'").pluck(:action, :subject_label))
      .to eq([ [ "budget.created", "Original (2026)" ], [ "budget.updated", "Original (2026)" ], [ "budget.deleted", "Original (2026)" ] ])
  end
end
