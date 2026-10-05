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

  describe "creating with details" do
    it "gives details without an organization the entry's organization" do
      org = create(:organization)
      other = create(:organization)
      asset = create(:tudla_accounting_account, category: :asset, organization: org)
      liability = create(:tudla_accounting_account, category: :liability, organization: org)

      entry = described_class.create!(organization: org, particulars: "Opening", transacted_at: Time.current, details_attributes: [
        { account: asset, tally: :debit, amount_cents: 1_000, currency: "USD" },
        { account: liability, tally: :credit, amount_cents: 1_000, currency: "USD", organization: other }
      ])

      expect(entry.details.find_by(account: asset).organization).to eq(org)
      expect(entry.details.find_by(account: liability).organization).to eq(other)
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
    let!(:period) { create(:tudla_accounting_period, organization: organization, from_date: Date.new(2026, 1, 1), thru_date: Date.new(2026, 12, 31).end_of_day) }
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

  describe ".create_from_ruby_hash" do
    let(:organization) { create(:organization, currency: "USD") }
    let!(:cash) { create(:tudla_accounting_account, code: "1000", category: :asset, organization: organization) }
    let!(:receivable) { create(:tudla_accounting_account, code: "1100", category: :asset, organization: organization) }
    let!(:receivable_eur) do
      create(:tudla_accounting_account, code: "1100-EUR", category: :asset, currency: "EUR", organization: organization, parent: receivable)
    end
    let!(:tax_payable) { create(:tudla_accounting_account, code: "2100", category: :liability, organization: organization) }
    let!(:sales) { create(:tudla_accounting_account, code: "4100", category: :income, organization: organization) }

    let(:invoice_hash) do
      {
        organization_type: "Organization",
        organization_id: organization.id,
        source_type: "Invoice",
        source_id: 123_456,
        particulars: "Invoice for landlord",
        transacted_at: "2026-04-27T09:12:36+10:00",
        details: [
          { account_code: "1100", amount: "USD 2750.00" },
          { account_code: "4100", amount: "USD 2500.00" },
          { account_code: "2100", amount: "USD 250.00" }
        ]
      }
    end

    def with_first_detail(changes)
      invoice_hash.merge(details: [ invoice_hash[:details].first.merge(changes).compact, *invoice_hash[:details].drop(1) ])
    end

    def detail_for(entry, account) = entry.details.find { |d| d.account == account }

    it "creates an entry, turning each signed amount into a debit or credit for its account" do
      entry = described_class.create_from_ruby_hash(invoice_hash)

      expect(entry).to be_persisted
      expect(entry).to have_attributes(organization: organization, source_type: "Invoice", source_id: 123_456,
                                       particulars: "Invoice for landlord", posted_at: nil,
                                       transacted_at: Time.iso8601("2026-04-27T09:12:36+10:00"))
      expect(entry.details.size).to eq(3)
      expect(detail_for(entry, receivable)).to have_attributes(tally: "debit", amount: Money.new(2750_00, "USD"), organization: organization)
      expect(detail_for(entry, sales)).to have_attributes(tally: "credit", amount: Money.new(2500_00, "USD"))
      expect(detail_for(entry, tax_payable)).to have_attributes(tally: "credit", amount: Money.new(250_00, "USD"))
    end

    it "treats a negative amount as a decrease to the account" do
      entry = described_class.create_from_ruby_hash(invoice_hash.merge(
        source_type: "Payment", particulars: "Payment from landlord",
        details: [ { account_code: "1100", amount: "USD -2750.00" }, { account_code: "1000", amount: "USD 2750.00" } ]
      ))

      expect(detail_for(entry, receivable)).to have_attributes(tally: "credit", amount: Money.new(2750_00, "USD"))
      expect(detail_for(entry, cash)).to have_attributes(tally: "debit", amount: Money.new(2750_00, "USD"))
    end

    it "sets posted_at when given (without posting to balances)" do
      entry = described_class.create_from_ruby_hash(invoice_hash.merge(posted_at: "2026-04-27T11:00:00Z"))
      expect(entry.posted_at).to eq(Time.iso8601("2026-04-27T11:00:00Z"))
      expect(TudlaAccounting::Balance.count).to eq(0)
    end

    it "reads every currency code, including ones Monetize only knows by a shared symbol" do
      %w[AUD NZD].each do |code|
        org = create(:organization, currency: code)
        create(:tudla_accounting_account, code: "1000", category: :asset, currency: code, organization: org)
        create(:tudla_accounting_account, code: "4000", category: :income, currency: code, organization: org)

        entry = described_class.create_from_ruby_hash(invoice_hash.merge(organization_id: org.id, details: [
          { account_code: "1000", amount: "#{code} 1,100.00" }, { account_code: "4000", amount: "#{code} 1100" }
        ]))

        expect(entry.details.map(&:amount)).to all(eq(Money.new(1100_00, code)))
      end
    end

    it "rejects an unknown currency code" do
      expect { described_class.create_from_ruby_hash(with_first_detail(amount: "XYZ 10.00")) }
        .to raise_error(ArgumentError, 'unknown currency XYZ in amount "XYZ 10.00"')
    end

    it "records foreign exchange details" do
      entry = described_class.create_from_ruby_hash(invoice_hash.merge(details: [
        { account_code: "1100-EUR", amount: "USD 15400.00", fx: { other_currency_amount: "EUR 10000.00", fx_rate: "1.54" } },
        { account_code: "4100", amount: "USD 15400.00" }
      ]))

      fx = detail_for(entry, receivable_eur).foreign_exchange
      expect(fx).to have_attributes(rate: BigDecimal("1.54"), foreign_amount: Money.new(10_000_00, "EUR"))
    end

    it "only looks up account codes within the given organization" do
      other = create(:organization)
      create(:tudla_accounting_account, code: "9999", organization: other)
      expect { described_class.create_from_ruby_hash(with_first_detail(account_code: "9999")) }
        .to raise_error(ArgumentError, "invalid account_code: 9999")
    end

    it "raises (and creates nothing) when the amounts do not balance" do
      expect { described_class.create_from_ruby_hash(with_first_detail(amount: "USD 2000.00")) }
        .to raise_error(ActiveRecord::RecordInvalid, /credit and debit amounts are not equal/)
      expect(described_class.count).to eq(0)
    end

    {
      "transacted_at that is not ISO 8601" => [ { transacted_at: "2026-04-27" }, "transacted_at must be a valid ISO 8601 datetime string" ],
      "transacted_at that is not a string" => [ { transacted_at: Time.current }, "transacted_at must be a valid ISO 8601 datetime string" ],
      "posted_at that is not ISO 8601" => [ { posted_at: "yesterday" }, "posted_at must be a valid ISO 8601 datetime string" ],
      "posted_at that is not a string" => [ { posted_at: Time.current }, "posted_at must be a valid ISO 8601 datetime string" ],
      "particulars that is not a string" => [ { particulars: 123 }, "particulars must be a string" ],
      "details that is not an array" => [ { details: "not an array" }, "details must be an array" ]
    }.each do |description, (changes, message)|
      it "rejects #{description}" do
        expect { described_class.create_from_ruby_hash(invoice_hash.merge(changes)) }.to raise_error(ArgumentError, message)
      end
    end

    it "rejects fewer than two details" do
      expect { described_class.create_from_ruby_hash(invoice_hash.merge(details: invoice_hash[:details].first(1))) }
        .to raise_error(ArgumentError, "details must have at least 2 elements")
    end

    {
      "a missing account_code" => [ { account_code: nil }, "each detail must have an account_code" ],
      "an unknown account_code" => [ { account_code: "INVALID" }, "invalid account_code: INVALID" ],
      "a missing amount" => [ { amount: nil }, "each detail must have an amount" ],
      "an amount that is not a string" => [ { amount: 123 }, "amount must be a string" ],
      "an fx node without other_currency_amount" => [ { fx: { fx_rate: "1.54" } }, "fx node must have an other_currency_amount" ],
      "an fx node without fx_rate" => [ { fx: { other_currency_amount: "EUR 10.00" } }, "fx node must have an fx_rate" ],
      "an fx currency that differs from the account's" => [ { fx: { other_currency_amount: "EUR 10.00", fx_rate: "1.5" } },
                                                           "fx currency does not match the account currency" ]
    }.each do |description, (changes, message)|
      it "rejects a detail with #{description}" do
        expect { described_class.create_from_ruby_hash(with_first_detail(changes)) }.to raise_error(ArgumentError, message)
      end
    end
  end

  describe "drafts, posting and reversal" do
    let(:organization) { create(:organization, currency: "USD") }
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
    let(:cash) { create(:tudla_accounting_account, code: "1000", category: :asset, organization: organization) }
    let(:capital) { create(:tudla_accounting_account, code: "3000", category: :equity, organization: organization) }

    def draft(cents = 100_00)
      entry = build(:tudla_accounting_entry, organization: organization, particulars: "Capital", transacted_at: Time.zone.local(2026, 2, 1))
      entry.details.build(account: cash, tally: :debit, amount_cents: cents, currency: "USD")
      entry.details.build(account: capital, tally: :credit, amount_cents: cents, currency: "USD")
      entry.tap(&:save!)
    end

    def cash_balance = TudlaAccounting::Balance.peek(cash, year).ending_amount_cents

    it "is a draft until posted" do
      entry = draft
      expect([ entry.draft?, entry.posted? ]).to eq([ true, false ])
      entry.post(entry.transacted_at)
      expect([ entry.draft?, entry.posted? ]).to eq([ false, true ])
    end

    it "needs every line above zero and in one currency" do
      expect(build(:tudla_accounting_detail, amount_cents: 0).tap(&:validate).errors[:amount_cents]).to eq([ "must be more than zero" ])

      entry = draft
      entry.details.first.currency = "EUR"
      expect(entry).not_to be_valid
      expect(entry.errors[:base]).to include("All lines must be in the same currency")
    end

    it "leaves lines being removed out of the balance check" do
      entry = draft
      entry.details.build(account: cash, tally: :debit, amount_cents: 50_00, currency: "USD")
      expect(entry).not_to be_valid
      entry.details.last.mark_for_destruction
      expect(entry).to be_valid
    end

    it "can't be changed or deleted once posted" do
      entry = draft
      entry.post(entry.transacted_at)

      expect(entry.update(particulars: "Changed")).to be(false)
      expect(entry.errors[:base]).to eq([ "A posted entry can't be changed; reverse it instead" ])
      entry.reload.details.to_a.first.amount_cents = 1
      expect(entry).not_to be_valid
      expect(entry.reload.destroy).to be(false)
      expect(entry.errors[:base]).to include("A posted entry can't be deleted; reverse it instead")
    end

    it "is reversed by a posted mirror entry on the given date" do
      entry = draft
      entry.post(entry.transacted_at)

      reversal = entry.reverse!(on: Date.new(2026, 3, 1))

      expect(reversal).to have_attributes(particulars: "Reversal of: Capital", related: entry, posted_at: Time.zone.local(2026, 3, 1))
      expect(reversal.details.map { |line| [ line.account.code, line.tally, line.amount_cents ] }).to contain_exactly([ "1000", "credit", 100_00 ], [ "3000", "debit", 100_00 ])
      expect(entry.reversal).to eq(reversal)
      expect(cash_balance).to eq(0)
    end

    it "mirrors foreign exchange on reversed lines" do
      entry = draft
      entry.details.first.build_foreign_exchange(other_currency: "EUR", other_currency_cents: 60_00, rate: BigDecimal("1.6667"))
      entry.save!
      entry.post(entry.transacted_at)

      fx = entry.reverse!(on: Date.new(2026, 3, 1)).details.find(&:credit?).foreign_exchange
      expect(fx).to have_attributes(other_currency: "EUR", other_currency_cents: 60_00, rate: BigDecimal("1.6667"))
    end

    it "says why it can't be reversed" do
      entry = draft
      expect(entry.reversal_blocker).to eq("Only a posted entry can be reversed")
      expect { entry.reverse!(on: Date.new(2026, 3, 1)) }.to raise_error(ArgumentError, "Only a posted entry can be reversed")

      entry.post(entry.transacted_at)
      expect(entry.reversal_blocker).to be_nil
      entry.reverse!(on: Date.new(2026, 3, 1))
      expect(entry.reversal_blocker).to eq("This entry has already been reversed")
    end

    it "closes a receivable it opened when reversed" do
      entry = draft
      entry.post(entry.transacted_at)
      carrying = create(:tudla_accounting_carrying_amount, detail: entry.details.first, related_party: organization, amount_cents: 100_00)

      expect(entry.reload.opens_carrying_amount?).to be(true)
      expect(entry.reversal_blocker).to be_nil
      entry.reverse!(on: Date.new(2026, 3, 1))
      expect(carrying.reload.amount_cents).to eq(0)
    end
  end
end
