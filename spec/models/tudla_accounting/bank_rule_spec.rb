require "rails_helper"

RSpec.describe TudlaAccounting::BankRule do
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1001", name: "Bank, EUR", category: "asset", currency: "EUR" },
      { code: "1020", name: "Savings", category: "asset" }, { code: "2200", name: "GST", category: "liability" },
      { code: "6200", name: "Software", category: "expense" }, { code: "6300", name: "Bank fees", category: "expense" }
    ], organization)
  end

  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :purchases, account: account("2200")) }
  let(:department) { TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department") }
  let(:ops) { department.dimension_values.create!(code: "OPS", name: "Ops") }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def rule(**attrs) = described_class.create!({ organization: organization, name: "Software", description_contains: "adobe", counter_account: account("6200") }.merge(attrs))

  def line(description, cents, on: Date.new(2026, 3, 5), bank: account("1000"))
    TudlaAccounting::BankStatementLine.create!(organization: organization, account: bank, occurred_on: on, description: description, amount_cents: cents,
                                               currency: bank.currency || "AUD", external_id: SecureRandom.hex(8))
  end

  describe "#matches?" do
    it "looks for the text in any case, then the direction, the amount's size and the account" do
      software = line("ADOBE *CREATIVE CLOUD", -54_99)
      expect(rule.matches?(software)).to be(true)
      expect(rule(description_contains: "dropbox").matches?(software)).to be(false)
      expect(rule(direction: "in").matches?(software)).to be(false)
      expect(rule(direction: "out").matches?(software)).to be(true)
      expect(rule(direction: "out", amount_min_cents: 60_00).matches?(software)).to be(false)
      expect(rule(amount_min_cents: 50_00, amount_max_cents: 55_00).matches?(software)).to be(true)
      expect(rule(amount_max_cents: 50_00).matches?(software)).to be(false)
      expect(rule(account: account("1020")).matches?(software)).to be(false)
      expect(rule(account: account("1000")).matches?(software)).to be(true)
      expect(rule(active: false).matches?(software)).to be(false)
      expect(rule(direction: "out").matches?(line("Adobe refund", 54_99))).to be(false)
    end
  end

  describe "validation" do
    it "checks amounts, accounts, the tax code and dimensions" do
      expect(described_class.new(organization: organization, name: "x", description_contains: "x", counter_account: account("6200"), amount_min_cents: 10, amount_max_cents: 5))
        .to have_attributes(valid?: false)
      same = described_class.new(organization: organization, name: "x", description_contains: "x", account: account("1000"), counter_account: account("1000"))
      expect(same).not_to be_valid
      expect(same.errors[:counter_account]).to eq([ "must be another account than the bank account" ])

      account("6300").deactivate!
      inactive = described_class.new(organization: organization, name: "x", description_contains: "x", counter_account: account("6300"))
      expect(inactive).not_to be_valid
      expect(inactive.errors[:counter_account]).to eq([ "is inactive" ])

      sales = department.dimension_values.create!(code: "SALES", name: "Sales")
      both = described_class.new(organization: organization, name: "x", description_contains: "x", counter_account: account("6200"), dimension_value_ids: [ ops.id, sales.id ])
      expect(both).not_to be_valid
      expect(both.errors[:dimension_value_ids]).to eq([ "can have one value of each dimension" ])

      other = create(:organization, currency: "AUD")
      theirs = TudlaAccounting::Account.create!(organization: other, code: "6200", name: "Theirs", category: :expense)
      foreign = described_class.new(organization: organization, name: "x", description_contains: "x", counter_account: theirs, account: theirs)
      expect(foreign).not_to be_valid
      expect(foreign.errors.attribute_names).to include(:account, :counter_account)
    end
  end

  describe "with the bank reconciler" do
    let(:reconciler) { TudlaAccounting::BankReconciler.new(account("1000")) }

    it "suggests the first rule in order for lines the books have no match for" do
      software = line("ADOBE *CREATIVE CLOUD", -55_00)
      fee = line("Account fee", -10_00)
      line("Deposit", 500_00)
      first = rule(name: "Adobe", position: 1)
      rule(name: "Anything Adobe", position: 2)
      fees = rule(name: "Fees", description_contains: "fee", counter_account: account("6300"), position: 3)

      expect(reconciler.rule_suggestions).to eq(software => first, fee => fees)
      expect(reconciler.rule_suggestions(ledger_suggested: [ software ])).to eq(fee => fees)
      expect(TudlaAccounting::BankReconciler.new(account("1020")).rule_suggestions).to eq({})
    end

    it "records a line by its rule, splitting out the tax and tagging the dimension" do
      software = line("ADOBE *CREATIVE CLOUD", -55_00)
      rule(tax_code: gst, dimension_value_ids: [ ops.id ], particulars: "Adobe subscription")

      result = reconciler.record_by_rules!
      entry = result[:recorded].sole
      expect(result[:problems]).to be_empty
      expect(entry).to have_attributes(particulars: "Adobe subscription", posted_at: Time.zone.local(2026, 3, 5))
      expect(entry.details.map { |d| [ d.account.code, d.tally, d.amount_cents, d.tax_role, d.tags.map(&:dimension_value), d.description ] }).to contain_exactly(
        [ "1000", "credit", 55_00, nil, [], "ADOBE *CREATIVE CLOUD" ], [ "6200", "debit", 50_00, "base", [ ops ], nil ], [ "2200", "debit", 5_00, "tax", [], nil ]
      )
      expect(software.reload).to be_matched
      expect(reconciler.rule_suggestions).to be_empty
    end

    it "leaves lines it can't record, recording the rest" do
      eur = TudlaAccounting::BankReconciler.new(account("1001"))
      line("Adobe EU", -40_00, bank: account("1001"))
      rule
      result = eur.record_by_rules!
      expect(result).to eq(recorded: [], problems: [ "Adobe EU: no EUR rate for 5 Mar 2026; enter one" ])

      expect { eur.create_entry!(line("Adobe EU", -1_00, bank: account("1001")), account: account("6200"), rate: "1.6", tax_code: gst) }
        .to raise_error(ArgumentError, "Tax can't be split from a EUR statement line; record it without a tax code")
    end
  end

  it "keeps the accounts it uses from being made inactive or deleted, and its tax code from being deleted" do
    rule(account: account("1020"), tax_code: gst)
    expect(account("6200").deactivation_blocker).to eq("6200 - Software is used by the bank rule Software; change it or make it inactive first")
    expect(account("1020").deactivation_blocker).to eq("1020 - Savings is used by the bank rule Software; change it or make it inactive first")
    expect(account("6200")).not_to be_deletable
    expect(gst.destroy).to be(false)
    expect(gst.errors[:base]).to eq([ "Recurring entries, bank rules, tax returns or contacts use GST; change them first" ])
  end

  it "keeps a tax code a recurring entry uses from being deleted" do
    template = TudlaAccounting::RecurringEntry.new(organization: organization, name: "Software", particulars: "Software", frequency: "monthly", starts_on: Date.new(2026, 1, 1))
    template.lines.build(account: account("6200"), tally: :debit, amount_cents: 100_00, tax_code: gst)
    template.lines.build(account: account("1000"), tally: :credit, amount_cents: 110_00)
    template.save!
    expect(gst.destroy).to be(false)
  end

  it "is on the audit trail" do
    record = rule
    record.update!(position: 5)
    record.destroy!
    expect(TudlaAccounting::AuditEvent.where(organization: organization).where("action LIKE 'bank_rule%'").pluck(:action, :subject_label))
      .to eq([ %w[bank_rule.created Software], %w[bank_rule.updated Software], %w[bank_rule.deleted Software] ])
  end
end
