require "rails_helper"

RSpec.describe TudlaAccounting::FiledTaxReturn do
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:months) { year.children.order(:from_date).to_a }
  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200")) }
  let(:form) do
    TudlaAccounting::TaxReturnForm.create!(organization: organization, name: "BAS").tap do |bas|
      bas.boxes.create!(label: "1A", name: "GST on sales", position: 10, parts_attributes: [ { source: "tax_code_tax", tax_code_id: gst.id } ])
    end
  end

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset" }, { code: "2200", name: "GST", category: "liability" }, { code: "4000", name: "Sales", category: "income" }
    ], organization)
    sale(2, 1000)
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def aud(amount) = Money.from_amount(amount, "AUD")
  def file(from: 1, thru: 3) = described_class.file!(form, from: months[from - 1].from_date, thru: months[thru - 1].thru_date)

  def sale(month, amount)
    gst
    entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Sale",
                                                         transacted_at: Time.zone.local(2026, month, 10).iso8601,
                                                         details: [ { account_code: "1100", amount: "AUD #{amount * 1.1}" }, { account_code: "4000", amount: "AUD #{amount}", tax_code: "GST" } ])
    entry.post(entry.transacted_at)
  end

  it "keeps the figures as filed, showing what the books say since" do
    TudlaAccounting::Current.set(actor: "Pat") { file }
    filed = described_class.sole
    expect(filed).to have_attributes(basis: "accrual", filed_by: "Pat", figures: [ { "label" => "1A", "name" => "GST on sales", "cents" => 100_00 } ])
    expect(filed.label).to eq("BAS, 1 Jan 2026 to 31 Mar 2026")
    expect(filed.changes).to be_empty

    sale(3, 500)
    form.boxes.create!(label: "X", name: "Added since", position: 20)
    expect(filed.comparison).to eq([ { label: "1A", name: "GST on sales", filed: aud(100), now: aud(150) }, { label: "X", name: "Added since", filed: nil, now: aud(0) } ])
    expect(filed.changes.map { |box| box[:label] }).to eq(%w[1A X])

    form.boxes.find_by!(label: "1A").update!(label: "1A*")
    expect(filed.comparison).to eq([ # a box renamed since is one gone and one new
      { label: "1A", name: "GST on sales", filed: aud(100), now: nil }, { label: "1A*", name: "GST on sales", filed: nil, now: aud(150) },
      { label: "X", name: "Added since", filed: nil, now: aud(0) }
    ])
  end

  it "refuses an overlapping filing until the one filed is withdrawn, with a reason" do
    filed = file
    expect { file(from: 3, thru: 4) }.to raise_error(ActiveRecord::RecordInvalid, /BAS, 1 Jan 2026 to 31 Mar 2026 was filed already; withdraw it first/)
    expect(file(from: 4, thru: 6)).to be_persisted

    expect { filed.withdraw!(reason: " ") }.to raise_error(ArgumentError, "Say why it is withdrawn")
    TudlaAccounting::Current.set(actor: "Sam") { filed.withdraw!(reason: " Missed an invoice ") }
    expect(filed).to have_attributes(withdrawn?: true, withdrawn_by: "Sam", withdrawn_reason: "Missed an invoice")
    expect { filed.withdraw!(reason: "Again") }.to raise_error(ArgumentError, "This return has already been withdrawn")
    expect(file).to be_persisted

    expect(TudlaAccounting::AuditEvent.where(organization: organization).where("action LIKE 'tax_return.%'").pluck(:action))
      .to eq(%w[tax_return.filed tax_return.filed tax_return.withdrawn tax_return.filed])
    expect(TudlaAccounting::AuditEvent.where(action: "tax_return.filed").first.details).to eq("figures" => { "1A" => 100_00 })
  end

  it "needs its dates in order and a known basis, and keeps its form" do
    bad = described_class.new(organization: organization, form: form, from_date: months[2].from_date, thru_date: months[0].thru_date, basis: "barter", filed_at: Time.current)
    expect(bad).not_to be_valid
    expect(bad.errors.attribute_names).to contain_exactly(:thru_date, :basis)

    file
    expect(form.destroy).to be(false)
    expect(form.errors[:base]).to eq([ "Returns of BAS have been filed; it stays with them" ])
  end
end
