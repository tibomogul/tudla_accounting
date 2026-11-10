require "rails_helper"
require_relative "../../support/configuration"

# An app with its own screens turns the pages off and keeps the JSON API, and the PDFs and
# emails, which need no pages.
RSpec.describe "Leaving the pages out", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:token) { TudlaAccounting::ApiToken.issue!(organization: organization, name: "Shop", permissions: %w[read]).last }

  around do |example|
    TudlaAccounting.configuration.pages = false
    Rails.application.reload_routes!
    example.run
  ensure
    TudlaAccounting.configuration.pages = true
    Rails.application.reload_routes!
  end

  it "draws only the API's routes" do
    get "/tudla_accounting"
    expect(response).to have_http_status(:not_found)
    get "/tudla_accounting/accounts"
    expect(response).to have_http_status(:not_found)
    expect(TudlaAccounting::Engine.routes.url_helpers).not_to respond_to(:accounts_path)

    get "/tudla_accounting/api/v1/organization", headers: { "Authorization" => "Bearer #{token}" }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "name")).to eq("Acme")
  end

  it "still makes a statement, without links to the pages" do
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([ { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "4000", name: "Sales", category: "income" } ], organization)
    northwind = TudlaAccounting::Contact.create!(organization: organization, name: "Northwind")
    TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 3, 10),
                                      lines_attributes: [ { description: "Work", unit_price_cents: 50_00, account: TudlaAccounting::Account.find_by!(organization: organization, code: "4000") } ]).approve!
    statement = TudlaAccounting::PartyStatement.call(organization: organization, type: :receivable, party: northwind, from: Date.new(2026, 3, 1), thru: Date.new(2026, 3, 31))
    html = TudlaAccounting::PdfViewsController.render(partial: "tudla_accounting/reports/party_statement", locals: { statement: statement, open_items: false })
    expect(html).to include("INV-0001")
    expect(html).not_to include("<a ")
    expect(TudlaAccounting::PdfMaker.statements([ statement ], open_items: false)).to start_with("%PDF-")
  end
end
