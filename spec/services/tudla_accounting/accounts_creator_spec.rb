require "rails_helper"

RSpec.describe TudlaAccounting::AccountsCreator, type: :service do
  let(:organization) { create(:organization, currency: "AUD") }

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)

  let(:chart) do
    [
      { "code" => "1000", "name" => "Assets", "category" => "asset", "children" => [
        { "code" => "1100", "name" => "Current Assets", "category" => "asset", "children" => [
          { "code" => "1110", "name" => "Cash", "category" => "asset" },
          { "code" => "1120", "name" => "Accounts Receivable", "category" => "asset", "currency" => "EUR" }
        ] },
        { "code" => "1500", "name" => "Equipment", "category" => "asset" },
        { "code" => "1505", "name" => "Accumulated Depreciation", "category" => "asset", "contra_account" => "1500" }
      ] },
      { "code" => "2000", "name" => "Liabilities", "category" => "liability" }
    ]
  end

  it "creates the whole tree and returns the created accounts" do
    created = nil
    expect { created = described_class.call(chart, organization) }.to change(TudlaAccounting::Account, :count).by(7)

    expect(created.map(&:code)).to eq(%w[1000 1100 1110 1120 1500 1505 2000])
    expect(account("1110").ancestors.map(&:code)).to eq(%w[1000 1100])
    expect(account("2000")).to be_root
    expect(account("1505").contra_account).to eq(account("1500"))
    expect(account("1505")).to be_contra
  end

  it "defaults each account's currency to the organization's" do
    described_class.call(chart, organization)
    expect(account("1110").currency).to eq("AUD")
    expect(account("1120").currency).to eq("EUR")
  end

  it "accepts symbol keys" do
    described_class.call([ { code: "1000", name: "Assets", category: :asset, children: [ { code: "1010", name: "Cash", category: :asset } ] } ], organization)
    expect(account("1010").parent).to eq(account("1000"))
  end

  it "creates accounts beneath an existing parent, which can also be a contra target" do
    parent = create(:tudla_accounting_account, code: "9999", category: :asset, organization: organization)

    described_class.call([
      { "code" => "1000", "name" => "Child", "category" => "asset" },
      { "code" => "2000", "name" => "Contra child", "category" => "asset", "contra_account" => "9999" }
    ], organization, parent.id)

    expect([ account("1000").parent, account("2000").parent ]).to all(eq(parent))
    expect(account("2000").contra_account).to eq(parent)
  end

  it "rejects a child whose category differs from its parent's" do
    parent = create(:tudla_accounting_account, code: "9999", category: :asset, organization: organization)
    expect { described_class.call([ { "code" => "2000", "name" => "Loan", "category" => "liability" } ], organization, parent.id) }
      .to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Attributes are not compatible with parent")
  end

  it "creates nothing if any account is invalid, however deep" do
    nested_invalid = [ { "code" => "1000", "name" => "Assets", "category" => "asset", "children" => [ { "code" => "1100", "name" => nil, "category" => "asset" } ] } ]
    expect { described_class.call(nested_invalid, organization) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(TudlaAccounting::Account.count).to eq(0)
  end

  it "creates nothing if a contra account's target does not exist" do
    expect { described_class.call([ { "code" => "1505", "name" => "Acc Dep", "category" => "asset", "contra_account" => "1500" } ], organization) }
      .to raise_error(ActiveRecord::RecordInvalid, /1500 not found for contra account 1505/)
    expect(TudlaAccounting::Account.count).to eq(0)
  end

  context "with another organization's accounts" do
    let(:other) { create(:organization) }
    let!(:other_equipment) { create(:tudla_accounting_account, code: "1500", category: :asset, organization: other) }

    it "never links a contra account to another organization's account" do
      expect { described_class.call([ { "code" => "1505", "name" => "Acc Dep", "category" => "asset", "contra_account" => "1500" } ], organization) }
        .to raise_error(ActiveRecord::RecordInvalid, /1500 not found/)
    end

    it "never creates accounts beneath another organization's account" do
      expect { described_class.new(chart, organization, other_equipment.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
