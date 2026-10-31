require "rails_helper"

RSpec.describe TudlaAccounting::ContactImporter do
  let(:organization) { create(:organization, currency: "AUD") }

  before do
    TudlaAccounting::AccountsCreator.call([ { code: "2200", name: "GST", category: "liability" }, { code: "4000", name: "Sales", category: "income" } ], organization)
    TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: TudlaAccounting::Account.find_by!(organization: organization, code: "2200"))
  end

  def file(rows, extension: ".csv")
    file = Tempfile.new([ "contacts", extension ])
    file.binmode
    file.write(extension == ".csv" ? CSV.generate { |csv| rows.each { |row| csv << row } } : TudlaAccounting::Reports::Table.new(rows).to_xlsx("Contacts"))
    file.flush
    file.path
  end

  def contacts = TudlaAccounting::Contact.where(organization: organization).order(:name)

  it "adds contacts, updating those already there by name, with their default account and tax code" do
    TudlaAccounting::Contact.create!(organization: organization, name: "Globex", phone: "1")
    result = described_class.call(organization, file([
      [ "Name", "Kind", "Email", "Phone", "Tax number", "Payment terms (days)", "Default account", "Default tax code", "Unknown column" ],
      [ "Northwind", "", "ap@northwind.test", "", "", "30", "4000", "GST", "x" ], [ "globex", "Supplier", "", "2", "", "", "", "", "" ], [ "", "", "", "", "", "", "", "", "" ]
    ]), ".csv")
    expect(result).to eq(added: 1, updated: 1)
    expect(contacts.map { |contact| [ contact.name, contact.kind, contact.phone, contact.payment_terms_days, contact.default_account&.code, contact.default_tax_code&.code ] })
      .to eq([ [ "Globex", "supplier", "2", nil, nil, nil ], [ "Northwind", "customer", nil, 30, "4000", "GST" ] ])
  end

  it "takes the currency they're invoiced in, blank for the organization's" do
    described_class.call(organization, file([ [ "Name", "Currency" ], [ "Northwind", "eur" ], [ "Globex", "" ], [ "Initech", "AUD" ] ]), ".csv")
    expect(contacts.map { |contact| [ contact.name, contact[:currency] ] }).to eq([ [ "Globex", nil ], [ "Initech", nil ], [ "Northwind", "EUR" ] ])
    expect { described_class.call(organization, file([ [ "Name", "Currency" ], [ "Hooli", "XYZ" ] ]), ".csv") }
      .to raise_error(ArgumentError, "Row 2: Currency is not a known currency code")
  end

  it "reads Excel files, numbers as Excel keeps them" do
    expect(described_class.call(organization, file([ [ "Name", "Payment terms", "Default account" ], [ "Initech", 14, 4000 ] ], extension: ".xlsx"), ".xlsx")).to eq(added: 1, updated: 0)
    expect(contacts.sole).to have_attributes(payment_terms_days: 14, default_account: TudlaAccounting::Account.find_by!(organization: organization, code: "4000"))
  end

  it "imports nothing when a row is wrong, saying which" do
    expect { described_class.call(organization, file([ [ "Email" ] ]), ".csv") }.to raise_error(ArgumentError, "The file has no Name column")
    expect do
      described_class.call(organization, file([ [ "Name", "Kind", "Email", "Default account", "Default tax code" ], [ "Fine", "", "", "", "" ],
                                                [ "", "friend", "nope", "9999", "VAT" ] ]), ".csv")
    end.to raise_error(ArgumentError, "Row 3: no account has the code 9999; Row 3: no tax code has the code VAT; Row 3: Name can't be blank, Kind is not included in the list, and Email is invalid")
    expect(contacts).to be_empty
  end
end
