require "rails_helper"

RSpec.describe TudlaAccounting::PaymentWithholding do
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:noabn) do
    TudlaAccounting::WithholdingCode.create!(organization: organization, code: "NOABN", name: "No ABN quoted", rate: "0.47", payable_account: account("2350"), withheld_on: "payment",
                                             exempt_up_to_cents: 75_00)
  end
  let(:supplier) { TudlaAccounting::Contact.create!(organization: organization, name: "Corner Florist", kind: "supplier", default_withholding_code: noabn) }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Bank", category: "asset" }, { code: "1020", name: "Dollar account", category: "asset", currency: "USD" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2350", name: "No-ABN withholding", category: "liability" },
      { code: "6000", name: "Flowers", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def bill(cents, **attributes)
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: Date.new(2026, 4, 1),
                                      lines_attributes: [ { description: "Flowers", unit_price_cents: cents, account: account("6000") } ], **attributes).approve!
  end

  def applied(*documents) = documents.map { |document| { document: document, amount_cents: document.total_cents } }

  it "withholds from the bills over the limit only, naming the others" do
    small, other, large = bill(40_00), bill(75_00), bill(75_01)
    decision = described_class.new(supplier, applied(small, other, large))
    expect([ decision.code, decision.base_cents, decision.reason ]).to eq([ noabn, 75_01, "The supplies on BILL-0001 and BILL-0002 are each $75.00 or less before tax" ])

    expect([ described_class.new(supplier, applied(small)).code, described_class.new(supplier, applied(large)).reason ]).to eq([ nil, nil ])
  end

  it "judges a foreign bill, and an amount applied to no bill, in the organization's currency" do
    dollars = bill(50_00, currency: "USD", exchange_rate: "1.6") # AUD 80.00
    expect(described_class.new(supplier, applied(dollars))).to have_attributes(code: noabn, base_cents: 50_00)
    expect(described_class.new(supplier, applied(bill(46_00, currency: "USD", exchange_rate: "1.6"))).code).to be_nil # AUD 73.60

    expect(described_class.new(supplier, [], unapplied_cents: 75_00).reason).to eq("What was applied to no bill is $75.00 or less before tax")
    expect(described_class.new(supplier, [], unapplied_cents: 50_00, exchange_rate: BigDecimal("1.6"))).to have_attributes(code: noabn, base_cents: 50_00)
    expect(described_class.new(supplier, applied(bill(10_00)), unapplied_cents: 20_00).reason).to eq("The supply on BILL-0003 and what was applied to no bill are each $75.00 or less before tax")
  end

  it "says nothing for a supplier with no code withheld on payment, and withholds everything without a limit" do
    expect(described_class.new(TudlaAccounting::Contact.create!(organization: organization, name: "Ledger & Co", kind: "supplier"), [], unapplied_cents: 10_00))
      .to have_attributes(code: nil, base_cents: 0, reason: nil)
    noabn.update!(exempt_up_to_cents: nil)
    expect(described_class.new(supplier.reload, applied(bill(10_00)))).to have_attributes(code: noabn, base_cents: 10_00, reason: nil)
  end

  it "leaves a payment from a foreign account at no rate yet unexplained when it is applied to no bill" do
    payment = TudlaAccounting::Payment.new(organization: organization, kind: "paid", contact: supplier, account: account("1020"), amount_cents: 10_00)
    payment.withholdings = []
    payment.explain_withholding([])
    expect(payment.not_withheld_reason).to eq("No reason given")
  end
end
