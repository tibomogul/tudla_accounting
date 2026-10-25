require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe TudlaAccounting::PdfMaker, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", address: "1 Main St\nSydney") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "4000", name: "Sales", category: "income" },
      { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
    TudlaAccounting.configuration.document_header = ->(org) { "#{org.name} Pty Ltd\nABN 12 345 678 901" }
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def text(pdf)
    expect(pdf).to start_with("%PDF-")
    PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n").squish
  end

  def invoice(kind = "sales_invoice", cents = 1_200_00)
    TudlaAccounting::Document.create!(organization: organization, kind: kind, contact: northwind, issued_on: Date.new(2026, 3, 10), due_on: Date.new(2026, 4, 9), reference: "PO 9",
                                      notes: "Pay to BSB 000-000", lines_attributes: [ { description: "Consulting – strategy", quantity: 2, unit_price_cents: cents / 2, account: account(kind == "bill" ? "6000" : "4000") } ]).approve!
  end

  it "makes an invoice's PDF as it prints, from the document header to the notes" do
    pdf = text(described_class.document(invoice))
    expect(pdf).to include("Acme Pty Ltd", "ABN 12 345 678 901", "Invoice", "INV-0001", "10 Mar 2026", "9 Apr 2026", "PO 9",
                           "Northwind", "1 Main St", "Consulting – strategy", "1,200.00", "Pay to BSB 000-000")
    expect(pdf).not_to include("Payments and credits", "Void invoice")
  end

  it "writes a foreign document's amounts as the organization's pages do" do
    euros = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 3, 10), currency: "EUR", exchange_rate: "1.6",
                                              lines_attributes: [ { description: "Work", unit_price_cents: 1_234_50, account: account("4000") } ])
    pdf = text(described_class.document(euros))
    expect(pdf).to include("AMOUNT (EUR)", "1,234.50")
    expect(pdf).not_to include("1.234,50")
  end

  it "makes statements, each on its own page" do
    invoice
    globex = TudlaAccounting::Contact.create!(organization: organization, name: "Globex")
    TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: globex, issued_on: Date.new(2026, 3, 12),
                                      lines_attributes: [ { description: "Work", unit_price_cents: 50_00, account: account("4000") } ]).approve!
    statements = [ northwind, globex ].map do |party|
      TudlaAccounting::PartyStatement.call(organization: organization, type: :receivable, party: party, from: Date.new(2026, 3, 1), thru: Date.new(2026, 3, 31))
    end
    pdf = described_class.statements(statements, open_items: false)
    pages = PDF::Reader.new(StringIO.new(pdf)).pages.map { |page| page.text.squish }
    expect(pages.size).to eq(2)
    expect(pages.first).to include("Acme Pty Ltd", "Statement of account", "Northwind", "INV-0001", "1,200.00")
    expect(pages.second).to include("Globex", "50.00")
    expect(text(described_class.statements(statements.first(1), open_items: true))).to include("Open items at 31 Mar 2026", "1,200.00")
  end

  it "makes a receipt for a payment received, and a payment notice for one made" do
    received = TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 3, 20),
                                                amount_cents: 1_500_00, reference: "EFT 7", notes: "Internal only", applications: [ { document: invoice, amount_cents: 1_200_00 } ])
    receipt = text(described_class.payment(received))
    expect(receipt).to include("Receipt", "20 Mar 2026", "EFT 7", "Received from Northwind", "INV-0001", "1,200.00", "Held as a credit to your account 300.00", "Total received 1,500.00")
    expect(receipt).not_to include("Internal only")

    bill = TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: northwind, issued_on: Date.new(2026, 3, 2), reference: "S-44",
                                             lines_attributes: [ { description: "Paper", unit_price_cents: 80_00, account: account("6000") } ]).approve!
    paid = TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 3, 21),
                                            amount_cents: 80_00, applications: [ { document: bill, amount_cents: 80_00 } ])
    expect(text(described_class.payment(paid))).to include("Payment notice", "Paid to Northwind", "BILL-0001 (your S-44)", "2 Mar 2026", "Total paid 80.00")
  end

  it "loads nothing from the network while it makes one" do
    html = %(<html><body><p>Offline</p><img src="http://192.0.2.1/tracker.png"><link rel="stylesheet" href="http://192.0.2.1/x.css"></body></html>)
    started = Time.current
    expect(text(described_class.from_html(html))).to eq("Offline")
    expect(Time.current - started).to be < 15 # an unreachable address it tried to load would hold it up until the timeout
  end

  describe "the stylesheet" do
    it "comes from the setting, a callable or a path, else the host's tailwind.css" do
      expect(described_class.stylesheet).to include(".tc-app")
      TudlaAccounting.configuration.pdf_stylesheet = -> { "body { color: red }" }
      expect(described_class.stylesheet).to eq("body { color: red }")
      file = Tempfile.create([ "styles", ".css" ]).tap { |io| io.write("p { margin: 0 }") && io.flush }
      TudlaAccounting.configuration.pdf_stylesheet = file.path
      expect(described_class.stylesheet).to eq("p { margin: 0 }")
    ensure
      file&.close
    end

    it "is needed" do
      allow(Rails.application.assets.load_path).to receive(:find).with("tailwind.css").and_return(nil)
      expect { described_class.stylesheet }.to raise_error(described_class::Error, "PDFs need the compiled stylesheet: build tailwind.css, or set pdf_stylesheet")
    end
  end

  it "says when it can't make one" do
    allow(TudlaAccounting).to receive(:pdf?).and_return(false)
    expect { described_class.document(invoice) }.to raise_error(described_class::Error, "PDFs need the ferrum gem")

    allow(TudlaAccounting).to receive(:pdf?).and_call_original
    allow(Ferrum::Browser).to receive(:new).and_raise(Ferrum::BinaryNotFoundError, "Could not find an executable for the browser")
    expect { described_class.from_html("<p>x</p>") }.to raise_error(described_class::Error, "The PDF couldn't be made (Could not find an executable for the browser)")
  end
end

RSpec.describe TudlaAccounting, ".pdf?" do
  around do |example|
    TudlaAccounting.remove_instance_variable(:@pdf) if TudlaAccounting.instance_variable_defined?(:@pdf)
    example.run
  ensure
    TudlaAccounting.remove_instance_variable(:@pdf) if TudlaAccounting.instance_variable_defined?(:@pdf)
  end

  it "is true when ferrum can be loaded, and false otherwise" do
    expect(TudlaAccounting.pdf?).to be(true)
    TudlaAccounting.remove_instance_variable(:@pdf)
    allow(TudlaAccounting).to receive(:require).with("ferrum").and_raise(LoadError)
    expect(TudlaAccounting.pdf?).to be(false)
  end
end
