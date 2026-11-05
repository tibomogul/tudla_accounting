require "rails_helper"

RSpec.describe TudlaAccounting::Payment, "tax withheld from a supplier when they're paid" do
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:supplier) { TudlaAccounting::Contact.create!(organization: organization, name: "Handy Repairs", kind: "supplier") }
  let(:noabn) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "NOABN", name: "No ABN quoted", rate: "0.47", payable_account: account("2350"), withheld_on: "payment") }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "1200", name: "Creditable tax", category: "asset" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "2350", name: "No-ABN withholding", category: "liability" }, { code: "6000", name: "Repairs", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def postings(entry) = entry.details.map { |detail| [ detail.account.code, detail.tally, detail.amount_cents ] }
  def rows = TudlaAccounting::WithheldTax.where(organization: organization).order(:id)

  def bill(cents = 1_000_00)
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 3, 10),
                                      lines_attributes: [ { description: "Repairs", unit_price_cents: cents, account: account("6000") } ]).approve!
  end

  def pay(amount_cents: 530_00, withholdings: [ { code: noabn, base_cents: 1_000_00 } ], applications: [], **attributes)
    described_class.record!(organization: organization, kind: "paid", contact: supplier, account: account("1010"), paid_on: Date.new(2026, 4, 2), amount_cents: amount_cents,
                            withholdings: withholdings, applications: applications, **attributes)
  end

  it "works the tax out from the amount, posts it to the code's account, settles the bill and keeps a row in the payment's month" do
    owed = bill
    payment = pay(applications: [ { document: owed, amount_cents: 1_000_00 } ])
    expect(postings(payment.entry)).to contain_exactly([ "2100-AUD", "debit", 1_000_00 ], [ "1010", "credit", 530_00 ], [ "2350", "credit", 470_00 ])
    expect(payment).to have_attributes(amount: aud(530), withheld: aud(470), settled: aud(1_000), unapplied: aud(0))
    expect(owed.reload).to have_attributes(payment_status: "paid", amount_due: aud(0))
    expect(rows.sole).to have_attributes(contact: supplier, withholding_code: noabn, payment: payment, document_line: nil, direction: "from_supplier", on: Date.new(2026, 4, 2),
                                         base_cents: 1_000_00, withheld_cents: 470_00)
    expect(TudlaAccounting::Reports::Withholding.new(organization, from: year.children.order(:from_date).to_a[3], thru: year.children.order(:from_date).to_a[3]).qap.sole)
      .to have_attributes(contact: supplier, withheld: aud(470))
  end

  it "keeps the tax given, and adds an opposite row when voided" do
    payment = pay(amount_cents: 500_00, withholdings: [ { code: noabn, withheld_cents: 470_00, base_cents: 970_00 } ])
    expect(rows.sole).to have_attributes(base_cents: 970_00, withheld_cents: 470_00)
    payment.void!(on: Date.new(2026, 4, 3), reason: "Paid the wrong supplier")
    expect(rows.map { |row| [ row.on, row.withheld_cents, row.reversal ] }).to eq([ [ Date.new(2026, 4, 2), 470_00, false ], [ Date.new(2026, 4, 3), -470_00, true ] ])
  end

  it "refunds only the cash paid" do
    payment = pay
    expect(described_class.credit_left_cents(payment)).to eq(530_00)
  end

  it "refuses a code withheld when the bill is approved, and a payment code anywhere but a supplier's payment" do
    on_approval = TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC120", name: "Contractors", rate: "0.02", payable_account: account("2350"))
    expect { pay(withholdings: [ { code: on_approval, withheld_cents: 2_00 } ]) }.to raise_error(ArgumentError, /WC120 is withheld when the bill is approved, not on the payment/)
    customer = TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "customer")
    expect { described_class.record!(organization: organization, kind: "received", contact: customer, account: account("1010"), paid_on: Date.new(2026, 4, 2), amount_cents: 1_00, withholdings: [ { code: noabn, withheld_cents: 1 } ]) }
      .to raise_error(ArgumentError, /NOABN has no account for tax withheld from you/)
    expect { described_class.record!(organization: organization, kind: "supplier_refund", contact: supplier, account: account("1010"), paid_on: Date.new(2026, 4, 2), amount_cents: 1_00, withholdings: [ { code: noabn, withheld_cents: 1 } ]) }
      .to raise_error(ArgumentError, /Only a payment received from a customer or made to a supplier can have tax withheld/)
    line = TudlaAccounting::Document.new(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 3, 10),
                                         lines_attributes: [ { description: "Repairs", unit_price_cents: 1_00, account: account("6000"), withholding_code: noabn } ])
    expect(line).not_to be_valid
    expect(line.errors.full_messages.to_sentence).to include("NOABN is withheld when the supplier is paid; record it on the payment")
    expect(rows).to be_empty
  end

  describe "its code" do
    it "needs the payable account only, and keeps when it's withheld once tax is posted under it" do
      code = TudlaAccounting::WithholdingCode.new(organization: organization, code: "X", name: "X", rate: "0.47", withheld_on: "payment", creditable_account: account("1200"))
      expect(code).not_to be_valid
      expect(code.errors.full_messages).to include("Payable account is needed: tax withheld when a supplier is paid is owed in it",
                                                   "Creditable account must be none: tax withheld when a supplier is paid is for suppliers only")
      expect(code.tap { |each| each.withheld_on = "later" }).not_to be_valid
      expect(noabn).to have_attributes(on_payment?: true, withheld_on_label: "When the supplier is paid")

      pay
      expect(noabn.update(withheld_on: "approval")).to be(false)
      expect(noabn.errors.full_messages.to_sentence).to include("its withheld on can't change")
    end
  end

  it "comes from a starter list, with only the payable account" do
    expect(TudlaAccounting::WithholdingCodeTemplates.add!(organization, "au_no_abn", payable_account: account("2350"), creditable_account: account("1200"))).to eq(1)
    expect(TudlaAccounting::WithholdingCode.find_by!(organization: organization, code: "NOABN"))
      .to have_attributes(rate: BigDecimal("0.47"), withheld_on: "payment", payable_account: account("2350"), creditable_account: nil)
  end
end
