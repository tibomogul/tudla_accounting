require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe TudlaAccounting::PdfMaker, type: :service do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both", address: "1 Main St\nSydney", postal_code: "2000") }

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

  it "prints on the organization's paper" do
    TudlaAccounting.configuration.pdf_paper = ->(org) { org == organization ? :Letter : :A4 }
    pages = PDF::Reader.new(StringIO.new(described_class.document(invoice))).pages
    expect(pages.first.attributes[:MediaBox]).to eq([ 0, 0, 612, 792 ])
  end

  it "makes a tax invoice's PDF with the tax_registration setting's wording" do
    TudlaAccounting.configuration.document_header = ->(org) { "#{org.name} Pty Ltd" }
    TudlaAccounting.configuration.tax_registration = ->(_org) { TudlaAccounting::TaxRegistration.australia("51 824 753 556") }
    pdf = text(described_class.document(invoice))
    expect(pdf).to include("Tax invoice", "ABN 51 824 753 556", "INV-0001", "No GST")
  end

  it "makes an invoice's PDF as it prints, from the document header to the notes" do
    pdf = text(described_class.document(invoice))
    expect(pdf).to include("Acme Pty Ltd", "ABN 12 345 678 901", "Invoice", "INV-0001", "10 Mar 2026", "9 Apr 2026", "PO 9",
                           "Northwind", "1 Main St", "2000", "Consulting – strategy", "1,200.00", "Pay to BSB 000-000")
    expect(pdf).not_to include("Payments and credits", "Void invoice")
  end

  context "with tax certificates" do
    let(:peso_books) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }
    let(:quarter) { TudlaAccounting::FilingQuarters.new(peso_books).of(Date.new(2026, 2, 1)) }
    let(:report) { TudlaAccounting::Reports::SupplierCertificates.new(peso_books, quarter) }

    before do
      TudlaAccounting::PeriodCreator.call(peso_books, 2026)
      TudlaAccounting::AccountsCreator.call([
        { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2300", name: "Withholding payable", category: "liability" }, { code: "6000", name: "Fees", category: "expense" }
      ], peso_books)
    end

    def withholding(number, name = "Contractors (corporate)")
      TudlaAccounting::WithholdingCode.create!(organization: peso_books, code: number, name: name, rate: "0.02", payable_account: TudlaAccounting::Account.find_by!(organization: peso_books, code: "2300"))
    end

    def certified_bill(contact, code, cents)
      TudlaAccounting::Document.create!(organization: peso_books, kind: "bill", contact: contact, issued_on: Date.new(2026, 2, 10),
                                        lines_attributes: [ { description: "Work", unit_price_cents: cents, account: TudlaAccounting::Account.find_by!(organization: peso_books, code: "6000"), withholding_code: code } ]).approve!
    end

    it "fills BIR Form 2307 on its own paper, whatever pdf_paper says, with the signatures left to sign" do
      TudlaAccounting.configuration.withholding_agent = ->(org) { { name: org.name, tin: "000-111-222-00000", address: "1 Demo Street, Makati City", zip: "1223", signatory_name: "Maria Santos", signatory_title: "Finance Manager", signatory_tin: "000-333-444-000" } }
      supplier = TudlaAccounting::Contact.create!(organization: peso_books, name: "Sampaguita Consulting", kind: "supplier", tax_number: "123-456-789-000", address: "2 Made-up Road\nQuezon City", postal_code: "1100")
      certified_bill(supplier, withholding("WC120"), 1_234_567_89)

      pages = PDF::Reader.new(StringIO.new(described_class.supplier_certificates(report, report.certificates))).pages
      expect(pages.size).to eq(1)
      expect(pages.first.attributes[:MediaBox]).to eq([ 0, 0, 612, 936 ])
      text = pages.first.text.squish
      expect(text).to include("BIR Form No.", "2307", "January 2018 (ENCS)", "Part I – Payee Information", "Sampaguita Consulting", "2 Made-up Road Quezon City", "1100",
                              "Part II – Payor Information", "Bayanihan Corp.", "1 Demo Street, Makati City", "1223", "WC120", "1,234,567.89", "24,691.36",
                              "Maria Santos · Finance Manager · TIN 000-333-444-000", "CONFORME:")
      expect(text.delete(" ")).to include("123-456-789-000", "000-111-222-00000", "02", "01012026", "03312026")
    end

    it "keeps each sheet on one page with the longest names and addresses, and every line full, on as many sheets as the lines need" do
      long = "A very long name for a certificate that goes on and on past the end of its box, " * 4
      TudlaAccounting.configuration.withholding_agent = ->(_org) { { name: long, tin: "FOREIGN-1", address: long, zip: "1223", signatory_name: "Maria Santos", signatory_title: "Finance Manager", signatory_tin: "000-333-444-000" } }
      supplier = TudlaAccounting::Contact.create!(organization: peso_books, name: long, kind: "supplier", tax_number: "FOREIGN-99", address: long, postal_code: "W" * TudlaAccounting::Contact::POSTAL_CODE_LENGTH)
      12.times { |index| certified_bill(supplier, withholding("WX%03d" % index, long), 987_654_321_00) }

      pages = PDF::Reader.new(StringIO.new(described_class.supplier_certificates(report, report.certificates))).pages
      expect(pages.size).to eq(2)
      expect(pages.map { |page| page.text.squish }).to all(include("CONFORME:", "*NOTE: The BIR Data Privacy"))
      expect(pages.first.text).to include("FOREIGN-99", "9,876,543,210.00")
    end
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
    expect(text(described_class.payment(paid))).to include("Payment notice", "Paid to Northwind", "2000", "BILL-0001 (your S-44)", "2 Mar 2026", "Total paid 80.00")
  end

  it "loads nothing from the network while it makes one" do
    html = %(<html><body><p>Offline</p><img src="http://192.0.2.1/tracker.png"><link rel="stylesheet" href="http://192.0.2.1/x.css"></body></html>)
    started = Time.current
    expect(text(described_class.from_html(html))).to eq("Offline")
    expect(Time.current - started).to be < 15 # an unreachable address it tried to load would hold it up until the timeout
  end

  describe "the stylesheet" do
    it "comes from the setting, a callable or a path, else the engine's built one" do
      expect(described_class.stylesheet).to include(".tc-app").and(eq(File.read(TudlaAccounting::Engine.root.join("app/assets/builds/tudla_accounting.css"))))
      TudlaAccounting.configuration.pdf_stylesheet = -> { "body { color: red }" }
      expect(described_class.stylesheet).to eq("body { color: red }")
      file = Tempfile.create([ "styles", ".css" ]).tap { |io| io.write("p { margin: 0 }") && io.flush }
      TudlaAccounting.configuration.pdf_stylesheet = file.path
      expect(described_class.stylesheet).to eq("p { margin: 0 }")
    ensure
      file&.close
    end
  end

  it "says when it can't make one" do
    allow(TudlaAccounting).to receive(:pdf?).and_return(false)
    expect { described_class.document(invoice) }.to raise_error(described_class::Error, "PDFs need the ferrum gem or the pdf_renderer setting")

    allow(TudlaAccounting).to receive(:pdf?).and_call_original
    allow(Ferrum::Browser).to receive(:new).and_raise(Ferrum::BinaryNotFoundError, "Could not find an executable for the browser")
    expect { described_class.from_html("<p>x</p>") }.to raise_error(described_class::Error, "The PDF couldn't be made (Could not find an executable for the browser)")
  end

  describe "with the pdf_renderer setting" do
    let(:made) { [] }

    before do
      TudlaAccounting.configuration.pdf_renderer = lambda do |html, **page|
        made << [ html, page ]
        "%PDF-1.4 made elsewhere".encode(Encoding::UTF_8)
      end
    end

    it "is given the page with the styles inline, and the paper, in place of Chrome" do
      expect(Ferrum::Browser).not_to receive(:new)
      pdf = described_class.document(invoice)
      expect([ pdf, pdf.encoding, pdf.frozen? ]).to eq([ "%PDF-1.4 made elsewhere".b, Encoding::BINARY, true ])
      html, page = made.last
      expect(html).to include("INV-0001", ".tc-app")
      expect(page).to eq(paper: :A4, landscape: false, margin: 0.5)

      TudlaAccounting.configuration.pdf_paper = :Letter
      described_class.from_html("<p>x</p>", landscape: true)
      expect(made.last.last).to eq(paper: :letter, landscape: true, margin: 0.5)
    end

    it "says when it gives no PDF or fails" do
      TudlaAccounting.configuration.pdf_renderer = ->(_html, **) { nil }
      expect { described_class.from_html("<p>x</p>") }.to raise_error(described_class::Error, "The PDF couldn't be made (the pdf_renderer gave NilClass, not the PDF's bytes)")
      TudlaAccounting.configuration.pdf_renderer = ->(_html, **) { raise IOError, "the service is down" }
      expect { described_class.from_html("<p>x</p>") }.to raise_error(described_class::Error, "The PDF couldn't be made (the service is down)")
    end

    it "must be a callable" do
      expect { TudlaAccounting.configuration.pdf_renderer = "grover" }.to raise_error(ArgumentError, /pdf_renderer must be nil or a callable/)
    end
  end
end

RSpec.describe TudlaAccounting, ".pdf?" do
  include_context "with isolated TudlaAccounting configuration"

  around do |example|
    TudlaAccounting.remove_instance_variable(:@ferrum) if TudlaAccounting.instance_variable_defined?(:@ferrum)
    example.run
  ensure
    TudlaAccounting.remove_instance_variable(:@ferrum) if TudlaAccounting.instance_variable_defined?(:@ferrum)
  end

  it "is true when ferrum can be loaded or there's a pdf_renderer, and false otherwise" do
    expect(TudlaAccounting.pdf?).to be(true)
    TudlaAccounting.remove_instance_variable(:@ferrum)
    allow(TudlaAccounting).to receive(:require).with("ferrum").and_raise(LoadError)
    expect(TudlaAccounting.pdf?).to be(false)
    TudlaAccounting.configuration.pdf_renderer = ->(_html, **) { "%PDF" }
    expect(TudlaAccounting.pdf?).to be(true)
  end
end
