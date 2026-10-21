require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Contacts", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record] }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset" }, { code: "2200", name: "GST", category: "liability" }, { code: "4000", name: "Sales", category: "income" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def contact(name = "Northwind") = TudlaAccounting::Contact.find_by!(organization: organization, name: name)
  def names = css_select("tr[data-contact] td:first-child a").map(&:text)

  def owes(party, amount, due:)
    entry = build(:tudla_accounting_entry, organization: organization, particulars: "Invoice", transacted_at: Time.zone.local(2026, 3, 1))
    receivable = entry.details.build(account: account("1100"), tally: :debit, amount_cents: amount * 100, currency: "AUD", organization: organization)
    entry.details.build(account: account("4000"), tally: :credit, amount_cents: amount * 100, currency: "AUD", organization: organization)
    entry.save!
    entry.post(entry.transacted_at)
    TudlaAccounting::CarryingAmount.create!(detail: receivable, amount_cents: amount * 100, carrying_amount_type: :receivable, related_party: party, due_date: due)
  end

  it "adds a contact, shows what they owe, edits and deactivates them, on the activity log" do
    get routes.contacts_path
    expect(response.body).to include("No contacts yet.")
    get routes.new_contact_path(kind: "supplier")
    expect(css_select("select[name='contact[kind]'] option[selected]").map(&:text)).to eq([ "Supplier" ])

    post routes.contacts_path, params: { contact: { name: "Northwind", kind: "both", email: "ap@northwind.test", payment_terms_days: "30", default_account_id: account("4000").id,
                                                    address: "1 Main St\nSydney" } }
    expect(response).to redirect_to(routes.contact_path(contact))
    owes(contact, 100, due: Time.zone.local(2026, 3, 31))
    get routes.contact_path(contact)
    expect(css_select("[data-details]").first.text.squish).to include("ap@northwind.test", "30 days", "4000 - Sales", "1 Main St")
    expect(css_select("[data-open=receivable] h2").first.text.squish).to eq("They owe: 100.00")
    expect(css_select("[data-open=receivable] td").map { |cell| cell.text.squish }).to include("0.00", "100.00", "31 Mar 2026")
    expect(css_select("[data-open=payable]").first.text).to include("Nothing open.")
    expect(css_select("a").map { |link| link["href"] }).to include(routes.reports_statement_path(type: :receivable, party: "TudlaAccounting::Contact_#{contact.id}"))
    expect(response.body).not_to include(">Delete<")

    patch routes.contact_path(contact), params: { contact: { name: "", email: "x" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Name can&#39;t be blank", "Email is invalid")
    patch routes.contact_path(contact), params: { contact: { name: "Northwind", active: "0" } }
    expect(contact).not_to be_active
    get routes.contacts_path
    expect(names).to eq([])
    get routes.contacts_path(inactive: "1")
    expect(names).to eq([ "Northwind" ])

    delete routes.contact_path(contact)
    expect(flash[:alert]).to eq("Northwind has invoices, bills or payments; make it inactive instead")
    get routes.edit_contact_path(contact)
    get routes.activity_path(kind: "contact")
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish }).to eq([ "Changed the contact Northwind: active", "Added the contact Northwind" ])
  end

  it "searches, filters by side, downloads, imports and deletes" do
    %w[Northwind Globex].each { |name| TudlaAccounting::Contact.create!(organization: organization, name: name, kind: name == "Globex" ? "supplier" : "customer", email: "#{name.downcase}@test") }
    get routes.contacts_path(q: "glob")
    expect(names).to eq([ "Globex" ])
    get routes.contacts_path(kind: "customer")
    expect(names).to eq([ "Northwind" ])
    get routes.contacts_path(q: "nobody")
    expect(response.body).to include("No contacts match.")

    get routes.contacts_path(format: :csv, kind: "supplier")
    csv = CSV.parse(response.body)
    expect(csv).to eq([ [ "Name", "Kind", "Email", "Phone", "Address", "Tax number", "Payment terms", "Default account", "Default tax code", "Active", "Notes" ],
                        [ "Globex", "supplier", "globex@test", nil, nil, nil, nil, nil, nil, "yes", nil ] ])

    upload = ->(text, name = "contacts.csv") { Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: name) }
    post routes.import_contacts_path, params: { file: upload.call("Name,Payment terms\nInitech,14\nglobex,7\n") }
    expect(flash[:notice]).to eq("1 contact added and 1 updated from contacts.csv.")
    expect(contact("Globex").payment_terms_days).to eq(7)
    post routes.import_contacts_path, params: { file: upload.call("Name,Kind\nX,friend\n") }
    expect(flash[:alert]).to eq("No contacts were imported: row 2: Kind is not included in the list.")
    post routes.import_contacts_path
    expect(flash[:alert]).to start_with("No contacts were imported: param is missing")

    get routes.contact_path(contact("Initech"))
    delete routes.contact_path(contact("Initech"))
    expect(flash[:notice]).to eq("Contact Initech deleted.")
    get routes.activity_path(kind: "contact")
    expect(css_select("tbody tr").first.css("td").last.text.squish).to eq("Deleted the contact Initech")

    post routes.contacts_path, params: { contact: { name: "", payment_terms_days: "-3" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Payment terms days must be greater than or equal to 0")
  end

  context "when allowed only to read" do
    let(:permissions) { %i[read] }

    it "lists contacts but doesn't change them" do
      TudlaAccounting::Contact.create!(organization: organization, name: "Northwind")
      get routes.contacts_path
      expect(response.body).not_to include("New contact", "Import contacts")
      post routes.contacts_path, params: { contact: { name: "Globex" } }
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "keeps other organizations' contacts and accounts to themselves" do
    other = create(:organization, currency: "AUD")
    theirs = TudlaAccounting::Contact.create!(organization: other, name: "Theirs")
    get routes.contact_path(theirs)
    expect(response).to have_http_status(:not_found)
    TudlaAccounting::AccountsCreator.call([ { code: "4000", name: "Theirs", category: "income" } ], other)
    post routes.contacts_path, params: { contact: { name: "Mine", default_account_id: TudlaAccounting::Account.find_by!(organization: other).id } }
    expect(response).to have_http_status(:not_found)
  end
end
