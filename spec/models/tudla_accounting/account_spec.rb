require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe TudlaAccounting::Account, type: :model do
  it "builds from the factory" do
    expect(build(:tudla_accounting_account)).to be_valid
  end

  describe "validations" do
    it "requires name, code, and category" do
      account = TudlaAccounting::Account.new
      account.valid?
      expect(account.errors[:name]).to be_present
      expect(account.errors[:code]).to be_present
      expect(account.errors[:category]).to be_present
    end

    it "rejects a child with a different category than its parent" do
      parent = create(:tudla_accounting_account, category: :asset)
      child = build(:tudla_accounting_account, category: :liability, parent: parent, organization: parent.organization)
      expect(child).not_to be_valid
      expect(child.errors[:base]).to include("Attributes are not compatible with parent")
    end
  end

  describe "enums" do
    it "maps categories to expected integers" do
      expect(TudlaAccounting::Account.categories).to eq(
        "asset" => 0,
        "liability" => 1,
        "equity" => 2,
        "income" => 3,
        "expense" => 4
      )
    end
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:organization).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:balances).macro).to eq(:has_many) }
    it { expect(described_class.reflect_on_association(:details).macro).to eq(:has_many) }
    it { expect(described_class.reflect_on_association(:entries).macro).to eq(:has_many) }
    it { expect(described_class.reflect_on_association(:contra_account).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:contra_for).macro).to eq(:has_one) }
    it { expect(described_class.reflect_on_association(:bank_account_balance).macro).to eq(:has_one) }
  end

  describe "#debit_balance?" do
    it "returns true for asset and expense accounts" do
      expect(build(:tudla_accounting_account, category: :asset).debit_balance?).to be true
      expect(build(:tudla_accounting_account, category: :expense).debit_balance?).to be true
    end

    it "returns false for liability, equity, and income accounts" do
      expect(build(:tudla_accounting_account, category: :liability).debit_balance?).to be false
      expect(build(:tudla_accounting_account, category: :equity).debit_balance?).to be false
      expect(build(:tudla_accounting_account, category: :income).debit_balance?).to be false
    end
  end

  describe "#balance_sheet_account?" do
    it "is true for assets, liabilities and equity, and false for income and expenses" do
      results = TudlaAccounting::Account.categories.keys.to_h { |category| [ category, build(:tudla_accounting_account, category: category).balance_sheet_account? ] }
      expect(results).to eq("asset" => true, "liability" => true, "equity" => true, "income" => false, "expense" => false)
    end
  end

  describe "#code_with_name" do
    it "joins the code and name" do
      expect(build(:tudla_accounting_account, code: "1100", name: "Accounts Receivable").code_with_name).to eq("1100 - Accounts Receivable")
    end
  end

  describe "rules for the chart of accounts" do
    let(:organization) { create(:organization) }
    let(:equipment) { create(:tudla_accounting_account, code: "1500", category: :asset, organization: organization) }
    let(:capital) { create(:tudla_accounting_account, code: "3000", category: :equity, organization: organization) }
    let(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

    def post_to(account)
      entry = build(:tudla_accounting_entry, organization: organization, transacted_at: Time.zone.local(2026, 2, 1))
      entry.details.build(account: account, tally: :debit, amount_cents: 100, currency: "USD", organization: organization)
      entry.details.build(account: capital, tally: :credit, amount_cents: 100, currency: "USD", organization: organization)
      entry.save!
      year
      entry.post(entry.transacted_at)
    end

    it "keeps codes unique within an organization only" do
      equipment
      expect(build(:tudla_accounting_account, code: "1500", organization: organization)).not_to be_valid
      expect(build(:tudla_accounting_account, code: "1500", organization: create(:organization))).to be_valid
    end

    it "accepts known currency codes, upper-casing them" do
      expect(build(:tudla_accounting_account, currency: " eur ")).to be_valid.and(have_attributes(currency: "EUR"))
      expect(build(:tudla_accounting_account, currency: "")).to be_valid.and(have_attributes(currency: nil))
      expect(build(:tudla_accounting_account, currency: "XYZ").tap(&:validate).errors[:currency]).to eq([ "is not a known currency code" ])
    end

    it "fixes the category, parent and contra account once there are postings" do
      expect(equipment.structure_editable?).to be(true)
      post_to(equipment)

      expect(equipment.reload.structure_editable?).to be(false)
      expect(equipment.update(category: :expense)).to be(false)
      expect(equipment.errors[:base]).to include("Category, parent and contra account can't change once the account has postings")
      expect(equipment.reload.update(name: "Plant")).to be(true)
    end

    describe "roles" do
      let(:receivables) { create(:tudla_accounting_account, code: "1100", category: :asset, organization: organization, role: :receivable) }

      it "marks at most one account of each role per organization, looked up by role" do
        receivables
        expect(TudlaAccounting::Account.for_role(organization, :receivable)).to eq(receivables)
        expect(TudlaAccounting::Account.for_role(create(:organization), :receivable)).to be_nil
        expect { TudlaAccounting::Account.for_role!(organization, :payable) }
          .to raise_error(ArgumentError, "No account is marked as the Payables account for Organization #{organization.id}; mark one in the chart of accounts")
      end

      it "knows only its roles, each on accounts of a suitable category" do
        role_errors = ->(account, role) { account.tap { TudlaAccounting::AccountRoleAssigner.save(account, role) }.errors[:role] }

        expect(role_errors.call(build(:tudla_accounting_account, organization: organization), "petty_cash")).to eq([ "is not included in the list" ])
        expect(role_errors.call(build(:tudla_accounting_account, category: :asset, organization: organization), :retained_earnings)).to eq([ "needs an equity account for Retained earnings" ])
        expect(role_errors.call(build(:tudla_accounting_account, category: :asset, organization: organization), :realized_fx_gain)).to eq([ "needs an income or expense account for Realized exchange gains and losses" ])
        expect(TudlaAccounting::AccountRoleAssigner.save(build(:tudla_accounting_account, category: :expense, organization: organization), :realized_fx_gain)).to be(true)
        expect(build(:tudla_accounting_account).tap { |account| account.role = "" }).to have_attributes(role: nil)
      end

      # Its rules (what posting and closed periods leave in place) are AccountRoleAssigner's.
      it "changes its role only through AccountRoleAssigner" do
        message = [ "changes only through TudlaAccounting::AccountRoleAssigner" ]
        other = create(:tudla_accounting_account, code: "1150", category: :asset, organization: organization)

        expect(other.update(role: :receivable)).to be(false)
        expect(other.errors[:role]).to eq(message)
        expect(TudlaAccounting::Account.new(organization: organization, code: "1160", name: "Debtors", category: :asset, role: :receivable)
                 .tap(&:validate).errors[:role]).to eq(message)
        expect(receivables.update(role: nil)).to be(false)
        expect(receivables.reload.role).to eq("receivable")
      end

      # So nothing else saved meanwhile, by a callback say, skips AccountRoleAssigner's checks.
      it "lets only the account being assigned change its role, and only in the block" do
        other = create(:tudla_accounting_account, code: "2100", category: :liability, organization: organization)

        receivables.allowing_role_change { expect(other.update(role: :payable)).to be(false) }
        expect(other.errors[:role]).to eq([ "changes only through TudlaAccounting::AccountRoleAssigner" ])
        expect(receivables.update(role: nil)).to be(false)
      end

      # Nothing raises without them, so the dashboard and balances:check warn instead.
      describe ".missing_roles" do
        include_context "with isolated TudlaAccounting configuration"

        it "expects retained earnings, and receivables or payables once a source records them" do
          expect(TudlaAccounting::Account.missing_roles(organization)).to eq(%w[retained_earnings])

          TudlaAccounting.configuration.carrying_amount_sources = { "Invoice" => :receivable }
          expect(TudlaAccounting::Account.missing_roles(organization)).to eq(%w[receivable retained_earnings])
          receivables
          expect(TudlaAccounting::Account.missing_roles(organization)).to eq(%w[retained_earnings])
        end

        it "expects the exchange roles once an account is held in another currency" do
          create(:tudla_accounting_account, code: "1010", category: :asset, organization: organization, currency: organization.currency)
          expect(TudlaAccounting::Account.missing_roles(organization)).to eq(%w[retained_earnings])

          create(:tudla_accounting_account, code: "1020", category: :asset, organization: organization, currency: "EUR")
          expect(TudlaAccounting::Account.missing_roles(organization)).to eq(%w[retained_earnings unrealized_fx_gain realized_fx_gain])

          create(:tudla_accounting_account, code: "4900", category: :income, organization: organization, role: :realized_fx_gain)
          expect(TudlaAccounting::Account.missing_roles(organization)).to eq(%w[retained_earnings unrealized_fx_gain])
        end
      end

      it "lets an account with postings be renumbered, roles included" do
        post_to(receivables)
        expect(receivables.reload.update(code: "1199")).to be(true)
        expect(TudlaAccounting::Account.for_role(organization, :receivable).code).to eq("1199")
      end
    end

    it "can only be deleted with no postings, sub-accounts or contra accounts" do
      child = create(:tudla_accounting_account, category: :asset, organization: organization, parent: equipment)
      contra = create(:tudla_accounting_account, category: :asset, organization: organization, contra_account: equipment)

      expect([ equipment, child, contra ].map(&:deletable?)).to eq([ false, true, true ])
      expect(equipment.destroy).to be(false)
      expect(equipment.errors[:base]).to eq([ "Only an account with no postings, sub-accounts, contra accounts, recurring entries, bank rules, budgets or tax returns can be deleted" ])

      post_to(child)
      expect(child.reload.deletable?).to be(false)
      expect(contra.destroy).to be_truthy
    end
  end
end
