require "rails_helper"

RSpec.describe "Demo sign-in", type: :request do
  it "seeds Demo Co and opens its books" do
    post demo_session_path

    expect(response).to redirect_to(TudlaAccounting::Engine.routes.url_helpers.root_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Demo Co")
  end

  it "seeds Demo GmbH and opens its books, in euros, when asked for them" do
    allow(Demo::EuroSeeder).to receive(:new).and_wrap_original { |original, **| original.call(entries: 10) }
    post demo_session_path(books: "euro")

    follow_redirect!
    expect(response.body).to include("Demo GmbH")
    expect(response.body).to include('data-tc-decimal-mark=","')
    expect(Organization.find_by!(name: "Demo GmbH").currency).to eq("EUR")
  end

  it "seeds Demo Pilipinas Inc. and opens its books, in pesos, when asked for them" do
    allow(Demo::PesoSeeder).to receive(:new).and_wrap_original { |original, **| original.call(entries: 10) }
    post demo_session_path(books: "peso")

    follow_redirect!
    expect(response.body).to include("Demo Pilipinas Inc.")
    expect(response.body).to include('data-tc-decimal-mark="."')
    expect(Organization.find_by!(name: "Demo Pilipinas Inc.").currency).to eq("PHP")
  end

  it "shows the peso books' withholding on the reports' pages" do
    allow(Demo::PesoSeeder).to receive(:new).and_wrap_original { |original, **| original.call(entries: 10) }
    post demo_session_path(books: "peso")
    routes = TudlaAccounting::Engine.routes.url_helpers

    get routes.reports_withholding_path
    expect(response.body).to include("WC050", "WC120")
    get routes.reports_qap_path
    expect(response.body).to include("Dakila Consulting Corp.", "Matibay Builders Inc.")
    get routes.reports_supplier_certificates_path
    expect(response.body).to include("Dakila Consulting Corp.", "Matibay Builders Inc.", "Revenue District Office")
    expect(response.body).not_to include("data-missing-agent", "data-missing-tin")
    get routes.withholding_certificates_path
    expect(response.body).to include("Tala Logistics Inc.")
    get routes.reports_supplier_certificates_path(format: :pdf)
    expect(response.media_type).to eq("application/pdf")
  end
end
