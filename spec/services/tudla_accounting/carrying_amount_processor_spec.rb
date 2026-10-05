require "rails_helper"
require_relative "../../support/entry_sources"

RSpec.describe TudlaAccounting::CarryingAmountProcessor, type: :service do
  include_context "with entry source models"

  let(:organization) { create(:organization) }
  let(:receivable_account) { create(:tudla_accounting_account, code: "1100", category: :asset, organization: organization) }
  let(:payable_account) { create(:tudla_accounting_account, code: "2100", category: :liability, organization: organization) }
  let(:income_account) { create(:tudla_accounting_account, code: "4000", category: :income, organization: organization) }
  let(:expense_account) { create(:tudla_accounting_account, code: "5000", category: :expense, organization: organization) }
  let(:cash_account) { create(:tudla_accounting_account, code: "1000", category: :asset, organization: organization) }
  let(:foreign_currency_cash_account) { create(:tudla_accounting_account, code: "1001", category: :asset, organization: organization, parent: cash_account) }
  let(:foreign_currency_physical_bank_account) do
    create(:tudla_accounting_bank_account_balance, account: foreign_currency_cash_account, currency: "EUR", balance_cents: 10_000_00)
  end

  def detail(account, amount_cents, tally, fx: nil)
    attrs = { account: account, amount_cents: amount_cents, tally: tally, currency: organization.currency, organization: organization }
    attrs[:foreign_exchange_attributes] = fx if fx
    attrs
  end

  def create_entry(particulars, details, **attrs)
    create(:tudla_accounting_entry, organization: organization, particulars: particulars, details_attributes: details, **attrs)
  end

  context "when the entry is a receivable (Invoice)" do
    let(:entry) do
      create_entry("Invoice", [ detail(receivable_account, 10_000, "debit"), detail(income_account, 10_000, "credit") ],
                   source: Invoice.create!(due_date: 30.days.from_now))
    end

    it "creates a receivable carrying amount" do
      carrying_amount = nil
      expect { carrying_amount = described_class.call(entry: entry) }.to change(TudlaAccounting::CarryingAmount, :count).by(1)
      expect(carrying_amount.carrying_amount_type).to eq("receivable")
      expect(carrying_amount.amount_cents).to eq(10_000)
      expect(carrying_amount.due_date).to be_present
      expect(carrying_amount.related_party).to eq(organization)
    end
  end

  context "when the entry is a payable (Bill)" do
    let(:entry) do
      create_entry("Bill", [ detail(expense_account, 5_000, "debit"), detail(payable_account, 5_000, "credit") ],
                   source: Bill.create!(due_date: 30.days.from_now))
    end

    it "creates a payable carrying amount" do
      carrying_amount = nil
      expect { carrying_amount = described_class.call(entry: entry) }.to change(TudlaAccounting::CarryingAmount, :count).by(1)
      expect(carrying_amount.carrying_amount_type).to eq("payable")
      expect(carrying_amount.amount_cents).to eq(5_000)
      expect(carrying_amount.due_date).to be_present
    end
  end

  context "when the entry is a receipt (Payment)" do
    let!(:invoice_entry) do
      create_entry("Invoice", [ detail(receivable_account, 10_000, "debit"), detail(income_account, 10_000, "credit") ],
                   source: Invoice.create!(due_date: 30.days.from_now))
    end
    let(:payment_entry) do
      create_entry("Payment", [ detail(cash_account, 4_000, "debit"), detail(receivable_account, 4_000, "credit") ],
                   source_type: "Payment", related: invoice_entry)
    end

    before { described_class.call(entry: invoice_entry) }

    it "reduces the corresponding receivable carrying amount" do
      carrying_amount = invoice_entry.details.find_by(account: receivable_account).carrying_amount
      expect { described_class.call(entry: payment_entry) }.to change { carrying_amount.reload.amount_cents }.from(10_000).to(6_000)
    end
  end

  context "when the entry is a disbursement" do
    let!(:bill_entry) do
      create_entry("Bill", [ detail(expense_account, 5_000, "debit"), detail(payable_account, 5_000, "credit") ],
                   source: Bill.create!(due_date: 30.days.from_now))
    end
    let(:disbursement_entry) do
      create_entry("Disbursement", [ detail(payable_account, 2_000, "debit"), detail(cash_account, 2_000, "credit") ],
                   source_type: "Disbursement", related: bill_entry)
    end

    before { described_class.call(entry: bill_entry) }

    it "reduces the corresponding payable carrying amount" do
      carrying_amount = bill_entry.details.find_by(account: payable_account).carrying_amount
      expect { described_class.call(entry: disbursement_entry) }.to change { carrying_amount.reload.amount_cents }.from(5_000).to(3_000)
    end
  end

  context "when the entry is neither an invoice, bill, payment nor disbursement" do
    let(:entry) { create_entry("Journal", [ detail(cash_account, 100, "debit"), detail(income_account, 100, "credit") ]) }

    it "does nothing" do
      expect { expect(described_class.call(entry: entry)).to be_nil }.not_to change(TudlaAccounting::CarryingAmount, :count)
    end
  end

  context "when the entry has a foreign exchange detail" do
    let(:entry) do
      create_entry("Invoice in EUR", [
        detail(receivable_account, 15_400, "debit", fx: { other_currency: "EUR", other_currency_cents: 10_000, rate: 1.54 }), # 100 EUR @ 1.54
        detail(income_account, 15_400, "credit")
      ], source: Invoice.create!(due_date: 30.days.from_now))
    end

    it "creates a receivable carrying amount with foreign exchange info" do
      carrying_amount = nil
      expect { carrying_amount = described_class.call(entry: entry) }
        .to change(TudlaAccounting::CarryingAmount, :count).by(1)
        .and change(TudlaAccounting::CarryingAmountForex, :count).by(1)

      expect(carrying_amount.amount_cents).to eq(15_400)
      expect(carrying_amount.forex.other_currency).to eq("EUR")
      expect(carrying_amount.forex.other_currency_amount_cents).to eq(10_000)
      expect(carrying_amount.forex.transaction_rate).to eq(1.54)
    end
  end

  context "when a payment is made on a foreign exchange receivable" do
    let!(:invoice_entry) do
      create_entry("Invoice in EUR", [
        detail(receivable_account, 15_400, "debit", fx: { other_currency: "EUR", other_currency_cents: 10_000, rate: 1.54 }),
        detail(income_account, 15_400, "credit")
      ], source: Invoice.create!(due_date: 30.days.from_now))
    end

    before { described_class.call(entry: invoice_entry) }

    it "updates the receivable carrying amount and its forex record" do
      payment_entry = create_entry("Payment in EUR", [
        detail(cash_account, 7_700, "debit"), # 50 EUR @ 1.54
        detail(receivable_account, 7_700, "credit", fx: { other_currency: "EUR", other_currency_cents: 5_000, rate: 1.54 })
      ], source: Payment.create!, related: invoice_entry)

      carrying_amount = described_class.call(entry: payment_entry)

      expect(carrying_amount.amount_cents).to eq(7_700)
      expect(carrying_amount.forex.other_currency_amount_cents).to eq(5_000)
    end

    it "increases the balance of a foreign currency bank account it is deposited into" do
      foreign_currency_physical_bank_account
      payment_entry = create_entry("Payment in EUR", [
        detail(foreign_currency_cash_account, 7_700, "debit"),
        detail(receivable_account, 7_700, "credit", fx: { other_currency: "EUR", other_currency_cents: 5_000, rate: 1.54 })
      ], source: Payment.create!, related: invoice_entry)

      described_class.call(entry: payment_entry)

      expect(foreign_currency_physical_bank_account.reload.balance_cents).to eq(10_050_00)
    end
  end

  context "when a disbursement is made on a foreign exchange payable" do
    let!(:bill_entry) do
      create_entry("Bill in EUR", [
        detail(payable_account, 15_000_00, "credit", fx: { other_currency: "EUR", other_currency_cents: 10_000_00, rate: 1.5 }),
        detail(expense_account, 15_000_00, "debit")
      ], source: Bill.create!(due_date: 30.days.from_now))
    end

    before { described_class.call(entry: bill_entry) }

    it "updates the payable carrying amount and its forex record" do
      disbursement_entry = create_entry("Disbursement in EUR", [
        detail(cash_account, 7_700_00, "credit"),
        detail(payable_account, 7_700_00, "debit", fx: { other_currency: "EUR", other_currency_cents: 5_000_00, rate: 1.54 })
      ], source: Disbursement.create!, related: bill_entry)

      carrying_amount = described_class.call(entry: disbursement_entry)

      expect(carrying_amount.amount_cents).to eq(7_300_00)
      expect(carrying_amount.forex.other_currency_amount_cents).to eq(5_000_00)
    end

    it "decreases the balance of a foreign currency bank account it is withdrawn from" do
      foreign_currency_physical_bank_account
      disbursement_entry = create_entry("Disbursement in EUR", [
        detail(foreign_currency_cash_account, 7_700_00, "credit"),
        detail(payable_account, 7_700_00, "debit", fx: { other_currency: "EUR", other_currency_cents: 5_000_00, rate: 1.54 })
      ], source: Disbursement.create!, related: bill_entry)

      described_class.call(entry: disbursement_entry)

      expect(foreign_currency_physical_bank_account.reload.balance_cents).to eq(5_000_00)
    end

    it "does not fail when withdrawing from a foreign currency bank account without a foreign exchange detail" do
      foreign_currency_physical_bank_account
      disbursement_entry = create_entry("Disbursement", [
        detail(foreign_currency_cash_account, 7_700_00, "credit"),
        detail(payable_account, 7_700_00, "debit")
      ], source: Disbursement.create!, related: bill_entry)

      carrying_amount = described_class.call(entry: disbursement_entry)

      expect(carrying_amount.amount_cents).to eq(7_300_00)
      expect(carrying_amount.forex.other_currency_amount_cents).to eq(10_000_00)
      expect(foreign_currency_physical_bank_account.reload.balance_cents).to eq(10_000_00)
    end
  end
end
