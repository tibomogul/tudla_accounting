require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Tax invoices", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200")) }
  let(:northwind) { contact("51 824 753 556") }

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
                                            { code: "2200", name: "GST", category: "liability" }, { code: "4000", name: "Sales", category: "income" }, { code: "6000", name: "Costs", category: "expense" } ], organization)
    sign_in_as(organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def contact(number, name: "Northwind") = TudlaAccounting::Contact.create!(organization: organization, name: name, kind: "both", tax_number: number)
  def text(selector) = css_select(selector).map { |node| node.text.squish }
  def australian(abn) = TudlaAccounting.configuration.tax_registration = ->(_organization) { TudlaAccounting::TaxRegistration.australia(abn) }

  def document(kind: "sales_invoice", to: northwind, tax_inclusive: false, lines: nil)
    lines ||= [ { description: "Consulting", quantity: 1, unit_price_cents: 100_00, account: account("4000"), tax_code: gst }, { description: "Postage", quantity: 1, unit_price_cents: 5_00, account: account("4000") } ]
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: to, issued_on: Date.current, tax_inclusive: tax_inclusive, lines_attributes: lines)
  end

  it "prints a tax invoice with the seller's ABN, the buyer's, and which lines have GST" do
    australian("51 824 753 556")
    invoice = document
    get routes.document_path(invoice)
    expect(text("[data-document] h2").first).to eq("Draft tax invoice")

    invoice.approve!
    get routes.document_path(invoice)
    expect(text("[data-document] h2").first).to eq("Tax invoice")
    expect(text("[data-seller-tax-number]")).to eq([ "ABN 51 824 753 556" ])
    printed = text("[data-document]").first
    expect(printed).to include("ABN 51 824 753 556", "Northwind", "GST (10%)", "No GST", "Subtotal105.00", "GST10.00", "Total115.00")
    expect(printed).not_to include("Tax number")
    expect(css_select("[data-tax-registration-warning]")).to be_empty
  end

  it "names a zero-rate code on its lines" do
    australian("51 824 753 556")
    free = TudlaAccounting::TaxCode.create!(organization: organization, code: "FRE", name: "GST-free", rate: "0", kind: :sales, treatment: :zero_rated)
    get routes.document_path(document(lines: [ { description: "Export", quantity: 1, unit_price_cents: 5_00, account: account("4000"), tax_code: free } ]))
    printed = text("[data-document]").first
    expect(printed).to include("Export 1 5.00 GST-free")
    expect(printed).not_to include("FRE")
  end

  it "calls a tax-inclusive invoice's tax GST too" do
    australian("51 824 753 556")
    get routes.document_path(document(tax_inclusive: true))
    expect(text("[data-document]").first).to include("Total excluding GST", "GST included")
  end

  it "keeps a credit note's title, with the seller's ABN" do
    australian("51 824 753 556")
    get routes.document_path(document(kind: "sales_credit"))
    expect(text("[data-document] h2").first).to eq("Draft credit note")
    expect(text("[data-seller-tax-number]")).to eq([ "ABN 51 824 753 556" ])
  end

  it "puts no seller's ABN on a bill, and calls the supplier's number an ABN" do
    australian("51 824 753 556")
    get routes.document_path(document(kind: "bill", lines: [ { description: "Stationery", quantity: 1, unit_price_cents: 5_00, account: account("6000") } ]))
    expect(css_select("[data-seller-tax-number], [data-tax-registration-warning]")).to be_empty
    expect(text("[data-document]").first).to include("Draft bill", "ABN 51 824 753 556")
  end

  it "warns, off the printed document, when the seller's ABN is missing or fails" do
    australian(nil)
    invoice = document
    get routes.document_path(invoice)
    expect(text("[data-tax-registration-warning]").first).to include("doesn't show your ABN")
    expect(css_select("[data-seller-tax-number]")).to be_empty
    expect(css_select("[data-document] [data-tax-registration-warning]")).to be_empty

    australian("51 824 753 557")
    get routes.document_path(invoice)
    expect(text("[data-tax-registration-warning]").first).to include("51 824 753 557, doesn't pass the ABN check")
  end

  it "still approves an invoice without an ABN" do
    australian(nil)
    expect(document.approve!).to be_approved
  end

  it "prints a contact's number that fails the check as a tax number, and warns on their page" do
    australian("51 824 753 556")
    foreign = contact("DE123456789", name: "Müller AG")
    get routes.document_path(document(to: foreign))
    expect(text("[data-document]").first).to include("Tax number DE123456789")

    get routes.contact_path(foreign)
    expect(text("[data-tax-number-warning]").first).to include("DE123456789 doesn't pass the ABN check")
    get routes.contact_path(northwind)
    expect(css_select("[data-tax-number-warning]")).to be_empty
  end

  it "takes another country's wording, with no check" do
    TudlaAccounting.configuration.tax_registration = ->(_organization) { TudlaAccounting::TaxRegistration.new(label: "VAT reg no.", number: "123", tax_name: "VAT", invoice_title: "VAT invoice") }
    get routes.document_path(document)
    expect(text("[data-document] h2").first).to eq("Draft VAT invoice")
    expect(text("[data-seller-tax-number]")).to eq([ "VAT reg no. 123" ])
  end

  it "leaves documents as they were without the setting" do
    get routes.document_path(document)
    expect(text("[data-document] h2").first).to eq("Draft invoice")
    expect(css_select("[data-seller-tax-number], [data-tax-registration-warning]")).to be_empty
    printed = text("[data-document]").first
    expect(printed).to include("Tax number 51 824 753 556", "Tax10.00")
    expect(printed).not_to include("No GST", "No Tax")
    get routes.contact_path(northwind)
    expect(css_select("[data-tax-number-warning]")).to be_empty
  end
end
