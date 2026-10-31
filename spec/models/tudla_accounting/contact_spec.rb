require "rails_helper"

RSpec.describe TudlaAccounting::Contact do
  let(:organization) { create(:organization, currency: "AUD") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def contact(**attrs) = described_class.create!({ organization: organization, name: "Northwind" }.merge(attrs))

  it "tidies what is typed, checks it, and says which sides it is on" do
    northwind = contact(name: "  Northwind   Traders ", email: " ap@northwind.test ", phone: "", kind: "both", payment_terms_days: 30)
    expect(northwind).to have_attributes(name: "Northwind Traders", email: "ap@northwind.test", phone: nil, party_types: %i[receivable payable], kind_label: "Customer and supplier")
    expect(northwind.due_on(Date.new(2026, 3, 1))).to eq(Date.new(2026, 3, 31))
    supplier = contact(kind: "supplier")
    expect(supplier).to have_attributes(customer?: false, supplier?: true, party_types: [ :payable ])
    expect(supplier.due_on(Date.current)).to be_nil

    # The organization's own currency is kept as none.
    expect([ northwind.currency, northwind.foreign? ]).to eq([ "AUD", false ])
    expect(contact(name: "Euro", currency: " eur ")).to have_attributes(currency: "EUR", foreign?: true)
    expect(contact(name: "Home", currency: "AUD")[:currency]).to be_nil

    bad = described_class.new(organization: organization, name: " ", kind: "friend", email: "not an email", payment_terms_days: -1, currency: "xyz")
    expect(bad).not_to be_valid
    expect(bad.errors.attribute_names).to contain_exactly(:name, :kind, :email, :payment_terms_days, :currency)
    expect(bad.errors[:currency]).to eq([ "is not a known currency code" ])

    other = create(:organization, currency: "AUD")
    TudlaAccounting::AccountsCreator.call([ { code: "4000", name: "Theirs", category: "income" }, { code: "2200", name: "GST", category: "liability" } ], other)
    theirs = TudlaAccounting::TaxCode.create!(organization: other, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: TudlaAccounting::Account.find_by!(organization: other, code: "2200"))
    foreign = described_class.new(organization: organization, name: "x", default_account: TudlaAccounting::Account.find_by!(organization: other, code: "4000"), default_tax_code: theirs)
    expect(foreign).not_to be_valid
    expect(foreign.errors.attribute_names).to contain_exactly(:default_account, :default_tax_code)
  end

  it "is found by name, email or tax number, by side" do
    contact(name: "Northwind", email: "ap@northwind.test")
    contact(name: "Globex", tax_number: "51 824 753 556", kind: "supplier")
    contact(name: "Initech", kind: "both", active: false)
    scope = described_class.where(organization: organization)
    expect(scope.search("NORTH").pluck(:name)).to eq([ "Northwind" ])
    expect(scope.search("824").pluck(:name)).to eq([ "Globex" ])
    expect(scope.search("100%_").pluck(:name)).to eq([])
    expect(scope.customers.order(:name).pluck(:name)).to eq(%w[Initech Northwind])
    expect(scope.suppliers.active.pluck(:name)).to eq([ "Globex" ])
  end

  it "can be deleted only while nothing was ever owed by or to it, and keeps its default account and tax code" do
    northwind = contact(default_account: account("4000"))
    gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200"))
    northwind.update!(default_tax_code: gst)
    expect(account("4000")).not_to be_deletable
    expect(gst.destroy).to be(false)
    expect(gst.errors[:base]).to eq([ "Recurring entries, bank rules, tax returns, contacts or invoices and bills use GST; change them first" ])

    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: Time.zone.local(2026, 3, 1))
    receivable = entry.details.build(account: account("1100-AUD"), tally: :debit, amount_cents: 100_00, currency: "AUD", organization: organization)
    entry.details.build(account: account("4000"), tally: :credit, amount_cents: 100_00, currency: "AUD", organization: organization)
    entry.save!
    TudlaAccounting::CarryingAmount.create!(detail: receivable, amount_cents: 100_00, carrying_amount_type: :receivable, related_party: northwind)
    expect(northwind).not_to be_deletable
    expect(northwind.destroy).to be(false)
    expect(northwind.errors[:base]).to eq([ "Northwind has invoices, bills or payments; make it inactive instead" ])

    other = contact(name: "Globex")
    other.update!(phone: "02 9999 0000")
    other.destroy!
    expect(TudlaAccounting::AuditEvent.where(organization: organization, subject_label: "Globex").pluck(:action, :details))
      .to eq([ [ "contact.created", {} ], [ "contact.updated", { "changes" => { "phone" => [ nil, "02 9999 0000" ] } } ], [ "contact.deleted", {} ] ])
  end
end
