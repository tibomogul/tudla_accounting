require "rails_helper"

RSpec.describe TudlaAccounting::TaxReturnCalculator, type: :service do
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:march) { year.children.order(:from_date).third }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset" },
      { code: "2100", name: "Payables", category: "liability" }, { code: "2200", name: "GST", category: "liability" },
      { code: "2300", name: "PAYG withholding", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }, { code: "4100", name: "Exports", category: "income" },
      { code: "6000", name: "Supplies", category: "expense" }, { code: "6040", name: "Wages", category: "expense" }
    ], organization)
    [ gst, gstp, free ] # before the entries that use them
    book("Sale", 3, [ { account_code: "1100", amount: "AUD 1100.61" }, { account_code: "4000", amount: "AUD 1000.55", tax_code: "GST" } ])
    book("Export", 3, [ { account_code: "1100", amount: "AUD 300.00" }, { account_code: "4100", amount: "AUD 300.00", tax_code: "FRE" } ])
    book("Bill", 3, [ { account_code: "6000", amount: "AUD 55.00", tax_code: "GSTP" }, { account_code: "2100", amount: "AUD 55.00" } ], tax_inclusive: true)
    book("Wages", 3, [ { account_code: "6040", amount: "AUD 2000.40" }, { account_code: "2300", amount: "AUD 400.00" }, { account_code: "1000", amount: "AUD -1600.40" } ])
    book("April sale", 4, [ { account_code: "1100", amount: "AUD 11.00" }, { account_code: "4000", amount: "AUD 10.00", tax_code: "GST" } ])
  end

  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST on sales", rate: "0.1", kind: :sales, account: account("2200")) }
  let(:gstp) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GSTP", name: "GST on purchases", rate: "0.1", kind: :purchases, account: account("2200")) }
  let(:free) { TudlaAccounting::TaxCode.create!(organization: organization, code: "FRE", name: "GST-free", rate: 0, kind: :sales) }

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")

  def book(particulars, month, details, **options)
    entry = TudlaAccounting::Entry.create_from_ruby_hash({ organization_type: "Organization", organization_id: organization.id, particulars: particulars,
                                                          transacted_at: Time.zone.local(2026, month, 10).iso8601, details: details }.merge(options))
    entry.post(entry.transacted_at)
  end

  def bas
    form = TudlaAccounting::TaxReturnForm.from_template!(organization, "au_bas")
    box = ->(label) { form.boxes.find_by!(label: label) }
    { "G1" => [ [ "tax_code_gross", gst ], [ "tax_code_gross", free ] ], "G2" => [ [ "tax_code_base", free ] ], "G11" => [ [ "tax_code_gross", gstp ] ],
      "1A" => [ [ "tax_code_tax", gst ] ], "1B" => [ [ "tax_code_tax", gstp ] ] }.each do |label, parts|
      parts.each { |source, code| box.call(label).parts.create!(source: source, tax_code: code) }
    end
    box.call("W1").parts.create!(source: "account", account: account("6040"))
    box.call("W2").parts.create!(source: "account", account: account("2300"))
    form.reload
  end

  def figures(form, **options)
    described_class.call(form, from: march.from_date, thru: march.thru_date, **options)[:boxes].to_h { |row| [ row.box.label, row.amount ] }
  end

  it "fills a BAS from its tax codes, accounts and boxes, dropping the cents" do
    expect(figures(bas)).to eq(
      "G1" => aud(1_400), "G2" => aud(300), "G3" => aud(0), "G10" => aud(0), "G11" => aud(55), "1A" => aud(100), "1B" => aud(5),
      "W1" => aud(2_000), "W2" => aud(400), "Net GST" => aud(95)
    )
  end

  it "shows each box's parts, signed, and keeps cents unless the box drops them" do
    form = TudlaAccounting::TaxReturnForm.create!(organization: organization, name: "Test")
    sales = form.boxes.create!(label: "S", name: "Sales tax", position: 1, parts_attributes: [ { source: "tax_code_tax", tax_code_id: gst.id } ])
    form.boxes.create!(label: "N", name: "Net", position: 2, parts_attributes: [ { source: "box", from_box_id: sales.id }, { source: "tax_code_tax", tax_code_id: gstp.id, sign: -1 } ])
    form.boxes.create!(label: "Old", name: "Unused code", position: 3, parts_attributes: [ { source: "tax_code_base", tax_code_id: TudlaAccounting::TaxCode.create!(organization: organization, code: "OLD", name: "Old", rate: 0, kind: :sales, active: false).id } ])
    result = described_class.call(form.reload, from: march.from_date, thru: march.thru_date, basis: :cash)
    expect(result[:basis]).to eq(:cash)
    expect(result[:boxes].map { |row| [ row.box.label, row.amount, row.parts.map { |part| [ part.part.description, part.amount ] } ] }).to eq([
      [ "S", aud("100.06"), [ [ "Tax under GST", aud("100.06") ] ] ],
      [ "N", aud("95.06"), [ [ "The box S", aud("100.06") ], [ "less Tax under GSTP", aud(-5) ] ] ],
      [ "Old", aud(0), [ [ "Net amount taxed under OLD", aud(0) ] ] ]
    ])
  end

  it "drops the cents towards zero" do
    form = TudlaAccounting::TaxReturnForm.create!(organization: organization, name: "Test")
    form.boxes.create!(label: "R", name: "Refund", position: 1, whole_units: true, parts_attributes: [ { source: "tax_code_tax", tax_code_id: gst.id, sign: -1 } ])
    expect(figures(form.reload)).to eq("R" => aud(-100))
  end

  describe "the boxes" do
    let(:form) { TudlaAccounting::TaxReturnForm.create!(organization: organization, name: "Test") }
    let!(:first) { form.boxes.create!(label: "A", name: "First", position: 10) }

    it "use only boxes above them, which then stay above and can't be deleted" do
      second = form.boxes.create!(label: "B", name: "Second", position: 20, parts_attributes: [ { source: "box", from_box_id: first.id } ])
      below = form.boxes.new(label: "C", name: "Above", position: 5, parts_attributes: [ { source: "box", from_box_id: second.id } ])
      expect(below).not_to be_valid
      expect(below.errors[:base]).to eq([ "B must be a box above this one on the form" ])

      expect(first.update(position: 30)).to be(false)
      expect(first.errors[:position]).to eq([ "must stay above B, which uses this box" ])
      expect(first.destroy).to be(false)
      expect(first.errors[:base]).to eq([ "B uses A; change it first" ])
      expect(form.boxes.new(label: "A", name: "Again", position: 40)).not_to be_valid
    end

    it "keep only the source a part names, and the organization's own tax codes and accounts" do
      part = first.parts.create!(source: "account", account: account("6040"), tax_code: gst)
      expect(part.tax_code).to be_nil
      expect(first.parts.new(source: "tax_code_tax")).not_to be_valid
      expect(first.parts.new(source: "elsewhere", sign: 2).tap(&:valid?).errors.attribute_names).to include(:source, :sign)

      other = create(:organization, currency: "AUD")
      TudlaAccounting::AccountsCreator.call([ { code: "2200", name: "GST", category: "liability" } ], other)
      theirs = TudlaAccounting::TaxCode.create!(organization: other, code: "GST", name: "Theirs", rate: "0.1", kind: :sales, account: TudlaAccounting::Account.find_by!(organization: other, code: "2200"))
      first.parts.build(source: "tax_code_tax", tax_code: theirs)
      first.parts.build(source: "account", account: TudlaAccounting::Account.find_by!(organization: other, code: "2200"))
      expect(first).not_to be_valid
      expect(first.errors[:base]).to eq([ "GST isn't one of the organization's tax codes", "2200 isn't one of the organization's accounts" ])
    end

    it "keep the tax codes and accounts they use from being deleted" do
      code = TudlaAccounting::TaxCode.create!(organization: organization, code: "NEW", name: "Unused", rate: 0, kind: :sales)
      first.parts.create!(source: "tax_code_base", tax_code: code)
      first.parts.create!(source: "account", account: account("6040"))
      expect(code.destroy).to be(false)
      expect(code.errors[:base]).to eq([ "Recurring entries, bank rules, tax returns, contacts or invoices and bills use NEW; change them first" ])
      expect(account("6040")).not_to be_deletable
    end
  end

  it "lays out the templates, refusing one it doesn't know, all on the audit trail" do
    vat = TudlaAccounting::TaxReturnForm.from_template!(organization, "uk_vat")
    expect(vat.boxes.map(&:label)).to eq((1..9).map { |number| "Box #{number}" })
    expect(vat.boxes.find_by!(label: "Box 5").parts.map(&:description)).to eq([ "The box Box 3", "less The box Box 4" ])
    expect(vat.boxes.select(&:whole_units?).map(&:label)).to eq([ "Box 6", "Box 7", "Box 8", "Box 9" ])
    expect { TudlaAccounting::TaxReturnForm.from_template!(organization, "nz_gst") }.to raise_error(ArgumentError, /\AUnknown tax return template "nz_gst"/)

    vat.update!(name: "VAT")
    vat.boxes.find_by!(label: "Box 9").destroy!
    vat.destroy!
    events = TudlaAccounting::AuditEvent.where(organization: organization).where("action LIKE 'tax_return_form%'").order(:id)
    expect(events.map(&:action).tally).to eq("tax_return_form.created" => 1, "tax_return_form.updated" => 11, "tax_return_form.deleted" => 1)
    expect(events.where(action: "tax_return_form.updated").last(2).map(&:details)).to eq([ { "changes" => { "name" => [ "VAT return", "VAT" ] } }, { "box" => "Box 9", "change" => "removed" } ])
  end
end
