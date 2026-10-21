require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe TudlaAccounting::EmailDraft, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", email: "ap@northwind.test") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "4000", name: "Sales", category: "income" } ], organization)
  end

  def document(kind = "sales_invoice")
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: northwind, issued_on: Date.new(2026, 3, 1), due_on: (Date.new(2026, 3, 31) unless kind == "sales_credit"),
                                      lines_attributes: [ { description: "Work", unit_price_cents: 1_234_50, account: TudlaAccounting::Account.find_by!(organization: organization, code: "4000") } ]).approve!
  end

  it "starts an invoice's or credit note's email from its template, to the contact" do
    expect(described_class.for_document(document)).to eq(
      kind: "document", to: "ap@northwind.test", subject_line: "Invoice INV-0001 from Acme",
      message: "Hello Northwind,\n\nPlease find attached invoice INV-0001 for $1,234.50, due on 31 Mar 2026.\n\nThank you,\nAcme"
    )
    expect(described_class.for_document(document("sales_credit"))[:subject_line]).to eq("Credit note CN-0001 from Acme")
  end

  it "takes the templates the setting gives, keeping placeholders it doesn't know" do
    TudlaAccounting.configuration.document_email_templates = { invoice: { subject: "%{kind} %{number}: %{amount_due} owing (%{issued_on}) %{whatever}" } }
    draft = described_class.for_document(document)
    expect(draft[:subject_line]).to eq("Invoice INV-0001: $1,234.50 owing (1 Mar 2026) %{whatever}")
    expect(draft[:message]).to start_with("Hello Northwind") # the default body
    expect { TudlaAccounting.configuration.document_email_templates = { fax: {} } }.to raise_error(ArgumentError, /unknown email template "fax"/)
  end

  it "names an organization without a name by its label" do
    expect(described_class.organization_name(Struct.new(:id).new(4))).to eq(TudlaAccounting.organization_label(Struct.new(:id).new(4)))
  end
end
