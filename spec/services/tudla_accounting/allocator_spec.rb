require "rails_helper"
require_relative "../../support/entry_sources"

# Applying payments and credit notes to invoices and bills, and taking them off again.
RSpec.describe TudlaAccounting::Allocator, type: :service do
  include_context "with entry source models"

  let(:organization) { create(:organization, currency: "AUD") }
  let(:globex) { create(:organization, name: "Globex") }
  let(:initech) { create(:organization, name: "Initech") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting.configuration.related_party_method = :customer
    TudlaAccounting.configuration.realized_fx_gain_account_code = "4950"
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Cash", category: "asset" },
      { code: "1001", name: "Bank EUR", category: "asset", currency: "EUR" },
      { code: "1100", name: "Accounts Receivable", category: "asset", children: [
        { code: "1100-EUR", name: "Accounts Receivable - EUR", category: "asset", currency: "EUR" } ] },
      { code: "2100", name: "Accounts Payable", category: "liability" },
      { code: "4000", name: "Sales", category: "income" },
      { code: "4100", name: "Sales Returns", category: "income" },
      { code: "4950", name: "Realized FX Gain", category: "income" },
      { code: "5000", name: "Purchases", category: "expense" }
    ], organization)
  end

  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def balance(code) = TudlaAccounting::Balance.peek(account(code), year).ending_amount
  def on(month, day) = Time.zone.local(2026, month, day)
  def open_item(entry) = described_class.carrying_amount(entry).reload

  def post(lines, at:, particulars: "Entry", **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: particulars, transacted_at: at, **attrs)
    lines.each do |code, tally, amount, fx|
      line = entry.details.build(account: account(code), tally: tally, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
      line.build_foreign_exchange(other_currency: "EUR", other_currency_cents: (BigDecimal(fx[0].to_s) * 100).to_i, rate: BigDecimal(fx[1])) if fx
    end
    entry.save!
    entry.post(at)
    entry
  end

  def invoice(name, amount, due:, customer: globex, at: on(3, 1))
    post([ [ "1100", :debit, amount ], [ "4000", :credit, amount ] ], at: at, particulars: name,
         source: Invoice.create!(due_date: due, customer: customer))
  end

  def payment(name, amount, at:, customer: globex, related: nil)
    post([ [ "1000", :debit, amount ], [ "1100", :credit, amount ] ], at: at, particulars: name,
         source: Payment.create!(customer: customer), related: related)
  end

  def owed(as_of) = TudlaAccounting::AgingReportGenerator.call(organization: organization, report_type: :receivable, as_of_date: as_of)

  describe "a payment on account" do
    let!(:inv1) { invoice("Invoice 1", 300, due: on(3, 31)) }
    let!(:inv2) { invoice("Invoice 2", 200, due: on(3, 15)) }
    let!(:pay) { payment("Payment 1", 450, at: on(3, 20)) }

    it "is a credit for the customer until it is applied" do
      expect(open_item(pay)).to have_attributes(amount_cents: -450_00, credit?: true, related_party: globex)
      report = owed(Date.new(2026, 3, 20))
      expect(report[:totals][:total]).to eq(aud(50))
      expect(report[:details].values.flatten.map { |line| [ line[:entry].particulars, line[:outstanding], line[:credit] ] })
        .to eq([ [ "Invoice 1", aud(300), false ], [ "Invoice 2", aud(200), false ], [ "Payment 1", aud(-450), true ] ])
    end

    it "is applied in part, then the rest to the oldest due first" do
      allocation = described_class.allocate!(pay, inv1, amount_cents: 100_00, at: on(3, 21))
      expect(allocation).to have_attributes(amount_cents: 100_00, other_currency_cents: nil, allocated_at: on(3, 21), active?: true)
      expect([ open_item(inv1).amount_cents, open_item(pay).amount_cents ]).to eq([ 200_00, -350_00 ])

      made = described_class.allocate_oldest_first!(pay, at: on(3, 22))
      expect(made.map { |a| [ a.to.detail.entry.particulars, a.amount_cents ] }).to eq([ [ "Invoice 2", 200_00 ], [ "Invoice 1", 150_00 ] ])
      expect([ open_item(inv1).amount_cents, open_item(inv2).amount_cents, open_item(pay).amount_cents ]).to eq([ 50_00, 0, 0 ])
      expect(described_class.allocate_oldest_first!(pay, at: on(3, 23))).to eq([])

      expect(owed(Date.new(2026, 3, 21))[:totals][:total]).to eq(aud(50)) # the same net, whatever is applied
      expect(owed(Date.new(2026, 3, 22))[:details].values.flatten.map { |line| line[:entry].particulars }).to eq([ "Invoice 1" ])
    end

    it "is taken off again, restoring what was owed" do
      allocation = described_class.allocate!(pay, inv1, at: on(3, 21))
      expect(open_item(inv1).amount_cents).to eq(0)

      described_class.unallocate!(allocation, at: on(3, 25))
      expect(allocation.reload.reversed_at).to eq(on(3, 25))
      expect([ open_item(inv1).amount_cents, open_item(pay).amount_cents ]).to eq([ 300_00, -450_00 ])
      expect(owed(Date.new(2026, 3, 23))[:details].values.flatten.map { |line| line[:entry].particulars }).to eq([ "Invoice 2", "Payment 1" ])
      expect { described_class.unallocate!(allocation, at: on(3, 26)) }.to raise_error(ArgumentError, "This allocation has already been taken off")
    end

    it "keeps an invoice from being reversed while a payment is applied to it" do
      allocation = described_class.allocate!(pay, inv1, at: on(3, 21))
      expect(inv1.reload.reversal_blocker).to eq("Reverse the payments against it first")

      described_class.unallocate!(allocation, at: on(3, 22))
      expect(inv1.reload.reversal_blocker).to be_nil
    end

    it "is taken off everything when the payment is reversed" do
      described_class.allocate_oldest_first!(pay, at: on(3, 21))
      pay.reload.reverse!(on: Date.new(2026, 3, 25))

      expect(TudlaAccounting::Allocation.pluck(:reversed_at).uniq).to eq([ on(3, 25) ])
      expect([ open_item(inv1).amount_cents, open_item(inv2).amount_cents, open_item(pay).amount_cents ]).to eq([ 300_00, 200_00, 0 ])
      expect(owed(Date.new(2026, 3, 24))[:totals][:total]).to eq(aud(50))
      expect(owed(Date.new(2026, 3, 25))[:totals][:total]).to eq(aud(500))
    end

    it "is recorded in the audit trail" do
      allocation = described_class.allocate!(pay, inv1, amount_cents: 100_00, at: on(3, 21))
      described_class.unallocate!(allocation, at: on(3, 22))
      expect(TudlaAccounting::AuditEvent.where(subject: allocation).order(:id).pluck(:action, :subject_label, :details))
        .to eq([ [ "allocation.created", "Payment 1 to Invoice 1", { "amount_cents" => 100_00 } ], [ "allocation.reversed", "Payment 1 to Invoice 1", {} ] ])
    end

    it "refuses what can't be applied" do
      other_customers = invoice("Invoice 3", 50, due: on(3, 31), customer: initech)
      bill = post([ [ "5000", :debit, 10 ], [ "2100", :credit, 10 ] ], at: on(3, 1), source: Bill.create!(customer: globex))
      settled = invoice("Invoice 4", 10, due: on(3, 31))
      described_class.allocate!(pay, settled, at: on(3, 21))
      draft = build(:tudla_accounting_entry, organization: organization, particulars: "No receivable", transacted_at: on(3, 1))

      {
        [ inv1, pay ] => "Only a payment or credit note can be applied",
        [ pay, payment("Payment 2", 5, at: on(3, 20)) ] => "A payment or credit note can only be applied to an invoice or bill",
        [ pay, other_customers ] => "Both must be for the same customer or supplier",
        [ pay, bill ] => "Both must be receivables or both payables",
        [ pay, settled ] => "Nothing is owed on it",
        [ pay, draft ] => "No receivable has no receivable or payable to apply"
      }.each do |(from, to), message|
        expect { described_class.allocate!(from, to, at: on(3, 21)) }.to raise_error(ArgumentError, message)
      end
      expect { described_class.allocate!(pay, inv1, amount_cents: 301_00, at: on(3, 21)) }.to raise_error(ArgumentError, "That is more than is owed")
      expect { described_class.allocate!(pay, inv1, amount_cents: 0, at: on(3, 21)) }.to raise_error(ArgumentError, "Apply more than nothing")
      described_class.allocate!(pay, inv1, amount_cents: 300_00, at: on(3, 21))
      expect { described_class.allocate!(pay, inv2, amount_cents: 200_00, at: on(3, 21)) }.to raise_error(ArgumentError, "That is more than is left to apply")
      described_class.allocate!(pay, inv2, at: on(3, 21))
      expect { described_class.allocate!(pay, inv2, at: on(3, 21)) }.to raise_error(ArgumentError, "Nothing is left to apply")
    end

    it "refuses entries of another organization, reversed ones, and dates in a closed month" do
      other = create(:organization, currency: "AUD")
      foreign_charge = TudlaAccounting::CarryingAmount.new(detail: build(:tudla_accounting_detail, organization: other, tally: :debit), carrying_amount_type: :receivable, related_party: globex)
      expect { described_class.allocate!(pay, foreign_charge, at: on(3, 21)) }.to raise_error(ArgumentError, "Both must belong to the same organization")

      inv2.reverse!(on: Date.new(2026, 3, 25))
      expect { described_class.allocate!(pay, inv2.reload, at: on(3, 26)) }.to raise_error(ArgumentError, "A reversed entry can't be applied")

      year.children.order(:from_date).first(3).each(&:close!)
      expect { described_class.allocate!(pay, inv1, at: on(3, 21)) }.to raise_error(ArgumentError, "Mar 2026 is closed")
    end
  end

  it "applies a payment to the invoice it names, leaving any overpayment as a credit" do
    inv = invoice("Invoice 1", 300, due: on(3, 31))
    pay = payment("Payment 1", 350, at: on(3, 10), related: inv)

    expect(open_item(inv).amount_cents).to eq(0)
    expect(open_item(pay)).to have_attributes(amount_cents: -50_00, related_party: globex)
    expect(TudlaAccounting::Allocation.sole).to have_attributes(amount_cents: 300_00, allocated_at: on(3, 10))
  end

  it "takes the party from the invoice when the payment doesn't name one, and doesn't apply it to another party's invoice" do
    inv = invoice("Invoice 1", 300, due: on(3, 31))
    expect(open_item(payment("Payment 1", 100, at: on(3, 10), customer: nil, related: inv))).to have_attributes(amount_cents: 0, related_party: globex)

    elsewhere = payment("Payment 2", 100, at: on(3, 11), customer: initech, related: inv)
    expect(open_item(elsewhere)).to have_attributes(amount_cents: -100_00, related_party: initech)
    expect(open_item(inv).amount_cents).to eq(200_00)
  end

  it "applies a credit note like a payment, without cash" do
    inv = invoice("Invoice 1", 300, due: on(3, 31))
    note = post([ [ "4100", :debit, 120 ], [ "1100", :credit, 120 ] ], at: on(3, 12), particulars: "Credit note 1",
                source: CreditNote.create!(customer: globex), related: inv)

    expect(open_item(inv).amount_cents).to eq(180_00)
    expect(open_item(note).amount_cents).to eq(0)
    expect(note.settlement?).to be(true)
  end

  it "applies a supplier credit to a bill" do
    bill = post([ [ "5000", :debit, 300 ], [ "2100", :credit, 300 ] ], at: on(3, 1), particulars: "Bill 1", source: Bill.create!(customer: globex))
    credit = post([ [ "2100", :debit, 80 ], [ "5000", :credit, 80 ] ], at: on(3, 5), particulars: "Supplier credit 1",
                  source: SupplierCredit.create!(customer: globex))

    expect(open_item(credit)).to have_attributes(amount_cents: -80_00, credit?: true, payable?: true)
    described_class.allocate!(credit, bill, at: on(3, 6))
    expect(open_item(bill).amount_cents).to eq(220_00)
  end

  it "ignores a payment line on the wrong side (a refund), which it can't treat as a credit" do
    refund = post([ [ "1100", :debit, 20 ], [ "1000", :credit, 20 ] ], at: on(3, 5), source: Payment.create!(customer: globex))
    expect(refund.details.filter_map(&:carrying_amount)).to be_empty
  end

  describe "refunds" do
    def refund(name, amount, at:, related: nil, customer: globex)
      post([ [ "1100", :debit, amount ], [ "1000", :credit, amount ] ], at: at, particulars: name,
           source: Refund.create!(customer: customer), related: related)
    end

    let!(:inv) { invoice("Invoice 1", 300, due: on(3, 31)) }
    let!(:overpaid) { payment("Payment 1", 350, at: on(3, 10), related: inv) } # 50.00 credit

    it "pays a customer's credit back, leaving nothing owed either way" do
      back = refund("Refund 1", 50, at: on(3, 15), related: overpaid)

      expect(open_item(back)).to have_attributes(amount_cents: 0, charge?: true, related_party: globex, due_date: nil)
      expect(open_item(overpaid).amount_cents).to eq(0)
      expect(back.refund?).to be(true)
      expect(owed(Date.new(2026, 3, 14))[:totals][:total]).to eq(aud(-50))
      expect(owed(Date.new(2026, 3, 15))[:totals][:total]).to eq(aud(0))
    end

    it "leaves a refund of more than the credit owed by the customer, and one on its own to match later" do
      too_much = refund("Refund 1", 70, at: on(3, 15), related: overpaid)
      expect([ open_item(too_much).amount_cents, open_item(overpaid).amount_cents ]).to eq([ 20_00, 0 ])

      unmatched = refund("Refund 2", 30, at: on(3, 16), customer: initech)
      expect(open_item(unmatched)).to have_attributes(amount_cents: 30_00, related_party: initech)
      credit = payment("Payment 2", 30, at: on(3, 17), customer: initech)
      described_class.allocate!(credit, unmatched, at: on(3, 18))
      expect(open_item(unmatched).amount_cents).to eq(0)
    end

    it "gives the credit back when the refund is reversed" do
      back = refund("Refund 1", 50, at: on(3, 15), related: overpaid)
      expect(back.reload.reversal_blocker).to be_nil

      back.reverse!(on: Date.new(2026, 3, 20))
      expect(open_item(overpaid).amount_cents).to eq(-50_00)
      expect(open_item(back).amount_cents).to eq(0)
    end

    it "is taken by a supplier refund of a supplier's credit too" do
      credit = post([ [ "2100", :debit, 80 ], [ "5000", :credit, 80 ] ], at: on(3, 5), particulars: "Supplier credit 1", source: SupplierCredit.create!(customer: globex))
      back = post([ [ "1000", :debit, 80 ], [ "2100", :credit, 80 ] ], at: on(3, 6), particulars: "Supplier refund 1",
                  source: SupplierRefund.create!(customer: globex), related: credit)

      expect([ open_item(credit).amount_cents, open_item(back).amount_cents ]).to eq([ 0, 0 ])
      expect(balance("2100")).to eq(aud(0))
    end

    it "ignores a refund line on the wrong side" do
      odd = post([ [ "1000", :debit, 5 ], [ "1100", :credit, 5 ] ], at: on(3, 15), source: Refund.create!(customer: globex))
      expect(odd.details.filter_map(&:carrying_amount)).to be_empty
    end

    it "books the exchange difference on a foreign credit paid back at another rate, and moves the foreign bank balance" do
      bank = create(:tudla_accounting_bank_account_balance, account: account("1001"), currency: "EUR", balance_cents: 500_00)
      paid = post([ [ "1000", :debit, 160 ], [ "1100-EUR", :credit, 160, [ 100, "1.60" ] ] ], at: on(3, 10), particulars: "Payment EUR",
                  source: Payment.create!(customer: globex))
      back = post([ [ "1100-EUR", :debit, 170, [ 100, "1.70" ] ], [ "1001", :credit, 170 ] ], at: on(3, 20), particulars: "Refund EUR",
                  source: Refund.create!(customer: globex), related: paid)

      expect(TudlaAccounting::Allocation.find_by!(from: open_item(paid)).realized_entry.particulars).to eq("Realized exchange loss on Refund EUR")
      expect(balance("4950")).to eq(aud(-10))
      expect(balance("1100-EUR")).to eq(aud(0))
      expect(bank.reload.balance_cents).to eq(400_00)

      back.reload.reverse!(on: Date.new(2026, 3, 25))
      expect(bank.reload.balance_cents).to eq(500_00)
      expect(balance("4950")).to eq(aud(0))
      expect(open_item(paid).amount_cents).to eq(-160_00)
    end
  end

  describe "in a foreign currency" do
    def eur_invoice(name, eur, rate, at: on(3, 1))
      value = BigDecimal(eur.to_s) * BigDecimal(rate)
      post([ [ "1100-EUR", :debit, value, [ eur, rate ] ], [ "4000", :credit, value ] ], at: at, particulars: name,
           source: Invoice.create!(due_date: on(4, 1), customer: globex))
    end

    def eur_payment(name, eur, rate, at:, related: nil)
      value = (BigDecimal(eur.to_s) * BigDecimal(rate)).round(2)
      post([ [ "1000", :debit, value ], [ "1100-EUR", :credit, value, [ eur, rate ] ] ], at: at, particulars: name,
           source: Payment.create!(customer: globex), related: related)
    end

    it "settles the foreign amount at the invoice's rate and books the difference when applied" do
      inv = eur_invoice("Invoice EUR", 100, "1.54")               # 154.00
      pay = eur_payment("Payment EUR", 100, "1.60", at: on(3, 10)) # 160.00 on account
      expect(open_item(pay).forex.other_currency_amount_cents).to eq(-100_00)

      allocation = described_class.allocate!(pay, inv, other_currency_cents: 60_00, at: on(3, 12))
      expect(allocation).to have_attributes(amount_cents: 96_00, other_currency_cents: 60_00)       # 60 of the 160.00 paid for 100
      expect(allocation.realized_entry).to have_attributes(particulars: "Realized exchange gain on Invoice EUR", transacted_at: on(3, 12))
      expect(balance("4950")).to eq(aud("3.6"))                                                      # 60 x (1.60 - 1.54)
      expect(open_item(inv)).to have_attributes(amount_cents: 61_60)
      expect(open_item(pay)).to have_attributes(amount_cents: -64_00)

      described_class.allocate!(pay, inv, at: on(3, 13)) # the remaining 40 EUR
      expect(open_item(inv).amount_cents).to eq(0)
      expect(open_item(pay).amount_cents).to eq(0)
      expect(balance("1100-EUR")).to eq(aud(0))

      described_class.unallocate!(allocation, at: on(3, 20))
      expect(allocation.realized_entry.reload.reversal).to be_present
      expect(balance("4950")).to eq(aud("2.4")) # only the 40 EUR still applied
      expect(open_item(inv).forex.other_currency_amount_cents).to eq(60_00)
    end

    it "refuses more of the foreign amount than either side has, and another currency" do
      inv = eur_invoice("Invoice EUR", 100, "1.54")
      pay = eur_payment("Payment EUR", 50, "1.60", at: on(3, 10))
      expect { described_class.allocate!(pay, inv, other_currency_cents: 60_00, at: on(3, 12)) }.to raise_error(ArgumentError, "That is more than is left to apply")
      expect { described_class.allocate!(pay, inv, other_currency_cents: 0, at: on(3, 12)) }.to raise_error(ArgumentError, "Apply more than nothing")

      small = eur_invoice("Small EUR", 10, "1.54")
      expect { described_class.allocate!(pay, small, other_currency_cents: 20_00, at: on(3, 12)) }.to raise_error(ArgumentError, "That is more than is owed")

      open_item(pay).forex.update!(other_currency: "USD")
      expect { described_class.allocate!(pay, inv, at: on(3, 12)) }.to raise_error(ArgumentError, "The payment is in USD but the amount owed is in EUR")
      expect(described_class.allocate_oldest_first!(pay, at: on(3, 12))).to eq([]) # skips charges in another currency
    end

    it "uses a foreign credit's foreign amount in proportion against an invoice in the organization's currency" do
      inv = invoice("Invoice AUD", 80, due: on(3, 31))
      pay = eur_payment("Payment EUR", 100, "1.60", at: on(3, 10)) # 160.00

      allocation = described_class.allocate!(pay, inv, at: on(3, 12))
      expect(allocation).to have_attributes(amount_cents: 80_00, other_currency_cents: 50_00, realized_entry: nil)
      expect(open_item(pay).forex.other_currency_amount_cents).to eq(-50_00)
    end

    it "revalues a foreign credit held on account, as it is owed back in the foreign currency" do
      TudlaAccounting.configuration.unrealized_fx_gain_account_code = "4950"
      TudlaAccounting::ForexRate.create!(from: "EUR", to: "AUD", year: 2026, month: 3, day: 31, rate: BigDecimal("1.70"))
      eur_payment("Payment EUR", 100, "1.60", at: on(3, 10)) # 160.00 for 100 EUR, not yet applied

      TudlaAccounting::RevaluationEntryGenerator.call(organization, Date.new(2026, 3, 31), Date.new(2026, 4, 1))

      march = year.children.order(:from_date).third
      expect(TudlaAccounting::Balance.find_by(account: account("1100-EUR"), period: march).ending_amount).to eq(aud(-170)) # 100 EUR at 1.70 owed back
      expect(TudlaAccounting::Balance.find_by(account: account("4950"), period: march).ending_amount).to eq(aud(-10))      # a loss
    end

    it "posts no difference without a realized gain account" do
      TudlaAccounting.configuration.realized_fx_gain_account_code = nil
      allow(Rails.logger).to receive(:warn)
      inv = eur_invoice("Invoice EUR", 100, "1.54")
      eur_payment("Payment EUR", 100, "1.60", at: on(3, 10), related: inv)

      expect(TudlaAccounting::Allocation.sole.realized_entry).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/exchange difference on Invoice EUR not posted/)
    end
  end
end
