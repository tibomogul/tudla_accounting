require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "PDF downloads", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both") }
  let(:invoice) do
    TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 4, 1),
                                      lines_attributes: [ { description: "Consulting", unit_price_cents: 100_00, account: account("4000") } ]).approve!
  end
  let(:payment) do
    TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: account("1000"), paid_on: Date.new(2026, 4, 10),
                                     amount_cents: 100_00, applications: [ { document: invoice, amount_cents: 100_00 } ])
  end

  before do
    travel_to Time.zone.local(2026, 4, 15, 9)
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" },
      { code: "4000", name: "Sales", category: "income" }
    ], organization)
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def pdf_text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n").squish
  def statement_params = { type: "receivable", party: TudlaAccounting::PartyStatement.key(northwind), from: "2026-04-01", thru: "2026-04-30" }

  it "downloads an invoice, a receipt and statements, linked from their pages" do
    get routes.document_path(invoice)
    expect(css_select("a[href='#{routes.document_path(invoice, format: :pdf)}']").map(&:text)).to eq([ "Download PDF" ])
    get routes.document_path(invoice, format: :pdf)
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Content-Disposition"]).to start_with('attachment; filename="INV-0001.pdf"')
    expect(pdf_text).to include("Invoice", "INV-0001", "Northwind", "100.00")

    get routes.payment_path(payment)
    expect(response.body).to include("Download receipt", "Print receipt", "The receipt, as it prints")
    get routes.payment_path(payment, format: :pdf)
    expect(response.headers["Content-Disposition"]).to start_with('attachment; filename="receipt-Northwind-2026-04-10.pdf"')
    expect(pdf_text).to include("Receipt", "INV-0001", "Total received 100.00")

    get routes.reports_statement_path(statement_params)
    expect(response.body).to include("Download PDF")
    get routes.reports_statement_path(statement_params.merge(format: :pdf))
    expect(response.headers["Content-Disposition"]).to include("statement-northwind-2026-04-01-to-2026-04-30.pdf")
    expect(pdf_text).to include("Statement of account", "Northwind")
    get routes.reports_statements_path(statement_params.except(:party).merge(format: :pdf))
    expect(pdf_text).to include("Statement of account", "Northwind")
    get routes.reports_statement_path(type: "receivable", format: :pdf) # no party chosen
    expect(response).to have_http_status(:not_found)
  end

  it "names a draft's PDF by its kind" do
    draft = TudlaAccounting::Document.create!(organization: organization, kind: "sales_credit", contact: northwind, issued_on: Date.new(2026, 4, 1),
                                              lines_attributes: [ { description: "Refund", unit_price_cents: 10_00, account: account("4000") } ])
    get routes.document_path(draft, format: :pdf)
    expect(response.headers["Content-Disposition"]).to start_with(%(attachment; filename="draft-sales-credit-#{draft.id}.pdf"))
    expect(pdf_text).to include("Draft credit note")
  end

  it "offers no PDFs when the engine can't make them, and says why when one couldn't be made" do
    allow(TudlaAccounting).to receive(:pdf?).and_return(false)
    get routes.document_path(invoice)
    expect(response.body).not_to include("Download PDF")
    expect(response.body).to include("Print or save as PDF")
    get routes.document_path(invoice, format: :pdf)
    expect(response).to have_http_status(:not_found)
    get routes.payment_path(payment)
    expect(response.body).not_to include("Download receipt")

    allow(TudlaAccounting).to receive(:pdf?).and_call_original
    allow(TudlaAccounting::PdfMaker).to receive(:from_html).and_raise(TudlaAccounting::PdfMaker::Error, "The PDF couldn't be made (Chrome went away)")
    get routes.payment_path(payment, format: :pdf)
    expect(response).to redirect_to(routes.payment_path(payment))
    expect(flash[:alert]).to eq("The PDF couldn't be made (Chrome went away).")
  end
end
