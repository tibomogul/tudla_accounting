require "rails_helper"

# An account with sub-accounts holds what they add up to, in every period, so only an
# account without sub-accounts takes postings. The triggers behind it are in
# database_protection_spec.
RSpec.describe "Postings and sub-accounts" do
  let(:organization) { create(:organization, currency: "USD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:capital) { create(:tudla_accounting_account, code: "3100", category: :equity, organization: organization) }
  let(:expenses) { create(:tudla_accounting_account, code: "6000", name: "Expenses", category: :expense, organization: organization) }
  let(:message) { "6000 - Expenses has sub-accounts (6010, 6020), so it can't take postings; use one of them" }

  def sub_account(code, parent = expenses) = create(:tudla_accounting_account, code: code, category: parent.category, organization: organization, parent: parent)

  def draft(account)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: "Fees", transacted_at: Time.zone.local(2026, 2, 1))
    entry.details.build(account: account, tally: :debit, amount_cents: 12_50, currency: "USD", organization: organization)
    entry.details.build(account: capital, tally: :credit, amount_cents: 12_50, currency: "USD", organization: organization)
    entry
  end

  def posted(account) = draft(account).tap(&:save!).tap { |entry| entry.post(entry.transacted_at) }

  it "refuses a line on an account with sub-accounts, naming them" do
    sub_account("6020")
    sub_account("6010")
    entry = draft(expenses)

    expect(entry).not_to be_valid
    expect(entry.errors.full_messages).to eq([ "Details account #{message}" ])
    expect(draft(TudlaAccounting::Account.find_by!(code: "6010"))).to be_valid
  end

  it "keeps a draft written before its account took sub-accounts, but doesn't post it until it moves" do
    entry = draft(expenses).tap(&:save!)
    sub_account("6010")
    sub_account("6020")

    expect(entry.reload.update(particulars: "Bank fees")).to be(true)
    expect { entry.post(entry.transacted_at) }.to raise_error(ArgumentError, message)
    expect(entry.reload).to be_draft
    expect(TudlaAccounting::Balance.where(account: expenses)).to be_empty

    line = entry.details.find_by!(account: expenses)
    expect(line.update(account: expenses)).to be(true) # unchanged
    expect(line.update(account: TudlaAccounting::Account.find_by!(code: "6010"))).to be(true)
    expect(entry.reload.post(entry.transacted_at)).to be(true)
  end

  it "refuses an invoice whose line is on an account with sub-accounts" do
    create(:tudla_accounting_account, code: "1100", category: :asset, organization: organization, role: :receivable)
    sales = create(:tudla_accounting_account, code: "4000", name: "Sales", category: :income, organization: organization)
    contact = TudlaAccounting::Contact.create!(organization: organization, name: "Globex")
    invoice = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: contact, issued_on: Date.new(2026, 2, 1),
                                                lines_attributes: [ { description: "Work", quantity: 1, unit_price_cents: 100_00, account: sales } ])
    sub_account("4010", sales)

    expect { invoice.approve! }.to raise_error(ArgumentError, "Details account 4000 - Sales has sub-accounts (4010), so it can't take postings; use one of them")
    expect(invoice.reload).to be_draft
  end

  describe "a new sub-account" do
    it "isn't added beneath an account with postings of its own" do
      posted(expenses)
      child = build(:tudla_accounting_account, code: "6010", category: :expense, organization: organization, parent: expenses)

      expect(child).not_to be_valid
      expect(child.errors[:base]).to eq([ "6000 - Expenses has postings of its own, so it can't take sub-accounts; add the account beside it, or beneath a new account" ])
      # Drafts don't count, nor postings beneath it.
      other = create(:tudla_accounting_account, code: "6500", name: "Travel", category: :expense, organization: organization)
      draft(other).save!
      posted(sub_account("6510", other))
      expect(build(:tudla_accounting_account, code: "6520", category: :expense, organization: organization, parent: other)).to be_valid
    end

    it "isn't moved beneath one either" do
      posted(expenses)
      loose = create(:tudla_accounting_account, code: "6900", category: :expense, organization: organization)
      expect(loose.update(parent: expenses)).to be(false)
      expect(loose.errors[:base].sole).to start_with("6000 - Expenses has postings of its own")
    end

    it "isn't added beneath an account with an opening balance of its own" do
      cash = create(:tudla_accounting_account, code: "1000", name: "Cash", category: :asset, organization: organization)
      TudlaAccounting::StartingBalanceCreator.call(organization, year.from_date.to_date, [ { account_id: cash.id, amount_cents: 500_00 }, { account_id: capital.id, amount_cents: 500_00 } ], "USD")
      child = build(:tudla_accounting_account, code: "1010", category: :asset, organization: organization, parent: cash)

      expect(child).not_to be_valid
      expect(child.errors[:base]).to eq([ "1000 - Cash has an opening balance of its own, so it can't take sub-accounts; put the opening balance on another account first" ])
    end

    it "is added beneath an account whose opening balance is its sub-accounts'" do
      cash = create(:tudla_accounting_account, code: "1000", category: :asset, organization: organization)
      bank = sub_account("1010", cash)
      TudlaAccounting::StartingBalanceCreator.call(organization, year.from_date.to_date,
                                                   [ { account_id: cash.id, amount_cents: 500_00, children: [ { account_id: bank.id, amount_cents: 500_00 } ] },
                                                     { account_id: capital.id, amount_cents: 500_00 } ], "USD")
      expect(build(:tudla_accounting_account, code: "1020", category: :asset, organization: organization, parent: cash)).to be_valid
    end

    it "isn't added beneath the account holding a role other than receivables or payables" do
      retained = create(:tudla_accounting_account, code: "3900", name: "Retained earnings", category: :equity, organization: organization, role: :retained_earnings)
      child = build(:tudla_accounting_account, code: "3910", category: :equity, organization: organization, parent: retained)

      expect(child).not_to be_valid
      expect(child.errors[:base]).to eq([ "3900 - Retained earnings is the Retained earnings account, so it can't take sub-accounts; move the role to another account first" ])
      receivables = create(:tudla_accounting_account, code: "1100", category: :asset, organization: organization, role: :receivable)
      expect(build(:tudla_accounting_account, code: "1100-EUR", currency: "EUR", category: :asset, organization: organization, parent: receivables)).to be_valid
    end
  end

  it "gives a role other than receivables or payables only to an account without sub-accounts" do
    sub_account("6010")

    expect(TudlaAccounting::AccountRoleAssigner.save(expenses, :realized_fx_gain)).to be(false)
    expect(expenses.errors[:role]).to eq([ "Realized exchange gains and losses needs an account without sub-accounts, as it puts amounts on the account itself" ])
    expect(expenses.reload.role).to be_nil
  end
end
