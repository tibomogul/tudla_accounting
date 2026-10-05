require "rails_helper"
require_relative "../../support/entry_sources"

RSpec.describe TudlaAccounting::Entry, type: :model do
  describe "validations" do
    it "requires particulars" do
      entry = build(:tudla_accounting_entry, particulars: nil)
      org = entry.organization
      asset = create(:tudla_accounting_account, category: :asset, organization: org)
      liability = create(:tudla_accounting_account, category: :liability, organization: org)
      entry.details.build(account: asset, tally: :debit, amount_cents: 1_000, currency: "USD", organization: org)
      entry.details.build(account: liability, tally: :credit, amount_cents: 1_000, currency: "USD", organization: org)
      entry.valid?
      expect(entry.errors[:particulars]).to be_present
    end

    it "is invalid without balanced debit/credit details" do
      org = create(:organization)
      asset = create(:tudla_accounting_account, category: :asset, organization: org)
      liability = create(:tudla_accounting_account, category: :liability, organization: org)
      entry = build(:tudla_accounting_entry, organization: org)
      entry.details.build(account: asset, tally: :debit, amount_cents: 10_000, currency: "USD", organization: org)
      entry.details.build(account: liability, tally: :credit, amount_cents: 5_000, currency: "USD", organization: org)
      expect(entry).not_to be_valid
      expect(entry.errors[:base]).to include("The credit and debit amounts are not equal")
    end

    it "is valid with balanced debit and credit details in the same currency" do
      org = create(:organization)
      asset = create(:tudla_accounting_account, category: :asset, organization: org)
      liability = create(:tudla_accounting_account, category: :liability, organization: org)
      entry = build(:tudla_accounting_entry, organization: org)
      entry.details.build(account: asset, tally: :debit, amount_cents: 10_000, currency: "USD", organization: org)
      entry.details.build(account: liability, tally: :credit, amount_cents: 10_000, currency: "USD", organization: org)
      expect(entry).to be_valid
    end
  end

  describe "associations" do
    it { expect(described_class.reflect_on_association(:organization).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:source).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:related).macro).to eq(:belongs_to) }
    it { expect(described_class.reflect_on_association(:details).macro).to eq(:has_many) }
  end

  describe "#post" do
    include_context "with entry source models"

    let(:organization) { create(:organization) }
    let(:cash) { create(:tudla_accounting_account, code: "1000", category: :asset, organization: organization) }
    let(:receivable) { create(:tudla_accounting_account, code: "1100", category: :asset, organization: organization) }
    let(:payable) { create(:tudla_accounting_account, code: "2100", category: :liability, organization: organization) }
    let(:capital) { create(:tudla_accounting_account, code: "3000", category: :equity, organization: organization) }
    let(:sales) { create(:tudla_accounting_account, code: "4000", category: :income, organization: organization) }
    let!(:period) { create(:tudla_accounting_period, organization: organization, from_date: Date.new(2026, 1, 1), thru_date: Date.new(2026, 12, 31)) }
    let(:posted_at) { Time.zone.local(2026, 3, 10, 9) }

    def usd(cents) = Money.new(cents, "USD")
    def balance_for(account, period) = TudlaAccounting::Balance.find_by(account: account, period: period)

    def build_entry(lines, **attrs)
      entry = build(:tudla_accounting_entry, organization: organization, **attrs)
      lines.each do |account, tally, cents, fx|
        attrs = { account: account, tally: tally, amount_cents: cents, currency: "USD", organization: organization }
        attrs[:foreign_exchange_attributes] = fx if fx
        entry.details.build(attrs)
      end
      entry.tap(&:save!)
    end

    let(:investment) { build_entry([ [ cash, :debit, 100_00 ], [ capital, :credit, 100_00 ] ], particulars: "Initial investment") }

    it "posts every detail, stamps posted_at and returns true" do
      expect(investment.post(posted_at)).to be(true)

      expect(investment.reload.posted_at).to eq(posted_at)
      expect(investment.details.map(&:balance)).to all(be_present)
      expect(balance_for(cash, period).current_amount).to eq(usd(100_00))
      expect(balance_for(capital, period).current_amount).to eq(usd(100_00))
    end

    it "accumulates balances across entries, including split lines" do
      investment.post(posted_at)
      build_entry([ [ cash, :debit, 110_00 ], [ sales, :credit, 100_00 ], [ payable, :credit, 10_00 ] ], particulars: "Sale with tax")
        .post(posted_at + 1.day)

      expect(balance_for(cash, period).current_amount).to eq(usd(210_00))
      expect(balance_for(sales, period).current_amount).to eq(usd(100_00))
      expect(balance_for(payable, period).current_amount).to eq(usd(10_00))
    end

    it "keeps the books balanced (debit-side total equals credit-side total)" do
      investment.post(posted_at)
      build_entry([ [ cash, :debit, 110_00 ], [ sales, :credit, 100_00 ], [ payable, :credit, 10_00 ] ], particulars: "Sale with tax")
        .post(posted_at)

      debit_side = [ cash ].sum { |a| balance_for(a, period).current_amount }
      credit_side = [ capital, sales, payable ].sum { |a| balance_for(a, period).current_amount }
      expect(debit_side).to eq(credit_side)
    end

    it "creates a receivable carrying amount when posting an invoice" do
      invoice = Invoice.create!(due_date: Time.zone.local(2026, 4, 10))
      entry = build_entry([
        [ receivable, :debit, 154_00, { other_currency_cents: 100_00, other_currency: "EUR", rate: 1.54 } ],
        [ sales, :credit, 154_00 ]
      ], particulars: "Export sale", source: invoice, transacted_at: posted_at)

      expect { entry.post(posted_at) }.to change(TudlaAccounting::CarryingAmount, :count).by(1)

      carrying_amount = TudlaAccounting::CarryingAmount.last
      expect(carrying_amount).to have_attributes(detail: entry.details.find_by(account: receivable), amount_cents: 154_00,
                                                 carrying_amount_type: "receivable", due_date: invoice.due_date)
      expect(carrying_amount.forex).to have_attributes(other_currency: "EUR", other_currency_amount_cents: 100_00,
                                                       transaction_rate: BigDecimal("1.54"), conversion_date: posted_at.to_date)
    end

    it "rolls back every balance if a later detail cannot be posted" do
      entry = build_entry([ [ cash, :debit, 100_00 ], [ capital, :credit, 100_00 ] ], particulars: "Straddles a gap")
      allow(entry.details.last).to receive(:post).and_raise(ArgumentError, "boom")

      expect { entry.post(posted_at) }.to raise_error(ArgumentError, "boom")
      expect(TudlaAccounting::Balance.count).to eq(0)
      expect(entry.reload.posted_at).to be_nil
    end

    it "raises without posting when the entry is invalid" do
      entry = build(:tudla_accounting_entry, organization: organization, particulars: "Unbalanced")
      entry.details.build(account: cash, tally: :debit, amount_cents: 100_00, currency: "USD", organization: organization)
      entry.details.build(account: capital, tally: :credit, amount_cents: 90_00, currency: "USD", organization: organization)

      expect { entry.post(posted_at) }.to raise_error(ArgumentError, "entry must be valid")
      expect(TudlaAccounting::Balance.count).to eq(0)
    end

    it "raises when posted_at is not a time" do
      expect { investment.post(nil) }.to raise_error(ArgumentError, "posted_at must be a datetime")
      expect { investment.post("2026-03-10") }.to raise_error(ArgumentError, "posted_at must be a datetime")
    end

    it "raises when no period covers posted_at" do
      expect { investment.post(Time.zone.local(2028, 1, 1)) }.to raise_error(ArgumentError, "no valid period found for the posted date")
      expect(investment.reload.posted_at).to be_nil
    end
  end
end
