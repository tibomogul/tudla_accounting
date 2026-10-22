require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Dimensions on invoice and bill lines", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post] }
  let(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: account("2200")) }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind", kind: "both") }
  let(:department) { TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department") }
  let(:project) { TudlaAccounting::Dimension.create!(organization: organization, code: "PROJ", name: "Project") }
  let(:sales) { department.dimension_values.create!(code: "SALES", name: "Sales") }
  let(:eng) { department.dimension_values.create!(code: "ENG", name: "Engineering") }
  let(:apollo) { project.dimension_values.create!(code: "APOLLO", name: "Apollo") }

  before do
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "2100", name: "Payables", category: "liability", role: "payable" },
      { code: "2200", name: "GST", category: "liability" }, { code: "4000", name: "Sales", category: "income" }, { code: "6000", name: "Supplies", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def invoice_params(lines)
    { kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-04-10", due_on: "2026-04-24", lines: lines }
  end

  def line(description, price, dimensions = {})
    { description: description, quantity: "1", unit_price: price, account_id: account("4000").id, tax_code_id: gst.id, dimensions: dimensions }
  end

  def header = css_select("thead th").map(&:text)
  def chosen(name) = css_select("select[name='#{name}'] option[selected]").map(&:text)

  it "tags each line, shows the tags on the document's page, and tags the posting for profit and loss by dimension" do
    [ sales, eng, apollo ]
    get routes.new_document_path(kind: "sales_invoice")
    expect(header).to include("Tax", "Department", "Project", "Amount (AUD)")

    post routes.documents_path, params: { approve: "1", document: invoice_params(
      "0" => line("Consulting", "100.00", department.id.to_s => eng.id.to_s, project.id.to_s => apollo.id.to_s),
      "1" => line("Training", "50.00", department.id.to_s => sales.id.to_s, project.id.to_s => "")
    ) }
    invoice = TudlaAccounting::Document.sole
    expect(response).to redirect_to(routes.document_path(invoice))
    expect(invoice.lines.map(&:dimension_value_ids)).to eq([ [ eng.id, apollo.id ], [ sales.id ] ])

    get routes.document_path(invoice)
    expect(css_select("tr[data-line-dimensions]").map { |row| row.css("td").map(&:text) }).to eq([ [ "Consulting", "4000 - Sales", "Engineering", "Apollo" ], [ "Training", "4000 - Sales", "Sales", "—" ] ])
    expect(css_select("[data-document]").text).not_to include("Engineering") # not on the printed document

    tags = invoice.entry.details.to_h { |detail| [ [ detail.account.code, detail.amount_cents ], detail.tags.map(&:dimension_value) ] }
    expect(tags).to eq([ "1100", 165_00 ] => [], [ "4000", 100_00 ] => [ eng, apollo ], [ "4000", 50_00 ] => [ sales ], [ "2200", 10_00 ] => [], [ "2200", 5_00 ] => [])
    report = TudlaAccounting::DimensionReport.call(organization, department, from: Date.new(2026, 1, 1), thru: Date.new(2026, 12, 31))
    expect(report[:income].sole[:amounts].transform_keys { |value| value&.code }.transform_values(&:cents)).to include("SALES" => 50_00, "ENG" => 100_00)
  end

  it "changes and clears a draft's tags, and copies them onto a credit note" do
    [ sales, eng ]
    post routes.documents_path, params: { document: invoice_params("0" => line("Consulting", "100.00", department.id.to_s => eng.id.to_s)) }
    draft = TudlaAccounting::Document.sole
    get routes.edit_document_path(draft)
    expect(chosen("document[lines][0][dimensions][#{department.id}]")).to eq([ "Engineering" ])

    patch routes.document_path(draft), params: { document: invoice_params("0" => line("Consulting", "100.00", department.id.to_s => "").merge(id: draft.lines.sole.id)) }
    expect(draft.lines.reload.sole.dimension_value_ids).to eq([])
    patch routes.document_path(draft), params: { approve: "1", document: invoice_params("0" => line("Consulting", "100.00", department.id.to_s => sales.id.to_s).merge(id: draft.lines.sole.id)) }
    expect(draft.reload).to be_approved

    get routes.new_document_path(credit: draft.id)
    expect(chosen("document[lines][0][dimensions][#{department.id}]")).to eq([ "Sales" ])
  end

  it "keeps the form as it was without dimensions" do
    get routes.new_document_path(kind: "sales_invoice")
    expect(header).to eq([ "Description", "Quantity", "Unit price", "Account", "Tax", "Amount (AUD)", "Remove" ])
    post routes.documents_path, params: { document: invoice_params("0" => line("Consulting", "100.00").except(:dimensions)) }
    get routes.document_path(TudlaAccounting::Document.sole)
    expect(response.body).not_to include("line-dimensions")
  end

  it "takes only the organization's own values, one of each dimension" do
    theirs = TudlaAccounting::Dimension.create!(organization: create(:organization, currency: "AUD"), code: "DEPT", name: "Department")
    other = theirs.dimension_values.create!(code: "X", name: "Theirs")
    post routes.documents_path, params: { document: invoice_params("0" => line("Consulting", "100.00", theirs.id.to_s => other.id.to_s)) }
    expect(response).to have_http_status(:not_found)

    invoice = TudlaAccounting::Document.new(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 4, 10),
                                            lines_attributes: [ { description: "x", unit_price_cents: 1, account: account("4000"), dimension_value_ids: [ sales.id, eng.id ] } ])
    expect(invoice).not_to be_valid
    expect(invoice.errors.full_messages).to include("Lines dimension value ids can have one value of each dimension")
    invoice.lines.first.dimension_value_ids = [ other.id ]
    expect(invoice).not_to be_valid
    expect(invoice.errors.full_messages).to include("Lines dimension value ids must belong to the same organization")
    invoice.lines.first.dimension_value_ids = [ 0 ]
    expect(invoice).not_to be_valid
  end
end

RSpec.describe "JSON API: dimensions on document lines", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:secret) { TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: %w[read record post]).last }
  let(:headers) { { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" } }
  let(:northwind) { TudlaAccounting::Contact.create!(organization: organization, name: "Northwind") }
  let(:department) { TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department") }

  before do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "4000", name: "Sales", category: "income" } ], organization)
    department.dimension_values.create!(code: "SALES", name: "Sales")
  end

  def json = JSON.parse(response.body)

  def create_invoice(dimensions)
    post routes.api_v1_documents_path, headers: headers, params: {
      kind: "sales_invoice", contact_id: northwind.id, issued_on: "2026-04-10", approve: true,
      lines: [ { description: "Consulting", unit_price: "100.00", account_code: "4000", dimensions: dimensions } ]
    }.to_json
  end

  it "takes a line's dimensions by code, and shows them" do
    create_invoice("DEPT" => "SALES")
    expect(response).to have_http_status(:created)
    expect(json.dig("data", "lines", 0, "dimensions")).to eq("DEPT" => "SALES")
    entry = TudlaAccounting::Entry.find(json.dig("data", "entry_id"))
    get routes.api_v1_entry_path(entry), headers: headers
    expect(json.dig("data", "lines").map { |line| line["dimensions"] }).to eq([ {}, { "DEPT" => "SALES" } ])
  end

  it "names what it doesn't know" do
    create_invoice("TEAM" => "SALES")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json.dig("error", "message")).to eq("Line 1: there is no dimension TEAM")
    create_invoice("DEPT" => "OPS")
    expect(json.dig("error", "message")).to eq("Line 1: there is no Department value OPS")
    create_invoice("SALES")
    expect(json.dig("error", "message")).to eq("Line 1's dimensions must be an object of dimension code => value code")
    expect(TudlaAccounting::Document.count).to eq(0)
  end
end
