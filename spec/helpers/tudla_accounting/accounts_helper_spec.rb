require "rails_helper"

RSpec.describe TudlaAccounting::AccountsHelper, type: :helper do
  let(:organization) { create(:organization) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "4000", name: "Income", category: "income" },
      { code: "1000", name: "Assets", category: "asset", children: [
        { code: "1100", name: "Current", category: "asset", children: [ { code: "1110", name: "Cash", category: "asset" } ] }
      ] }
    ], organization)
  end

  let(:accounts) { TudlaAccounting::Account.where(organization: organization).order(:code).to_a }
  def account(code) = accounts.find { |candidate| candidate.code == code }

  it "lists the categories as select options" do
    expect(helper.account_category_options.first).to eq([ "Asset", "asset" ])
  end

  it "builds the tree by category, sub-accounts indented under their parent" do
    expect(helper.account_tree_rows(accounts).map { |label, category, rows| [ label, category, rows.map { |a, depth| [ a.code, depth ] } ] }).to eq([
      [ "Assets", "asset", [ [ "1000", 0 ], [ "1100", 1 ], [ "1110", 2 ] ] ],
      [ "Income", "income", [ [ "4000", 0 ] ] ]
    ])
  end

  it "offers other accounts as choices, leaving out the account and, for parents, its sub-accounts" do
    expect(helper.account_choices(accounts).size).to eq(4)
    expect(helper.account_choices(accounts, except: account("1100")).map(&:first)).to eq([ "1000 - Assets", "1110 - Cash", "4000 - Income" ])
    expect(helper.account_choices(accounts, except: account("1100"), exclude_descendants: true).map(&:first)).to eq([ "1000 - Assets", "4000 - Income" ])
    expect(helper.account_choices(accounts, except: TudlaAccounting::Account.new, exclude_descendants: true).size).to eq(4)
  end
end
