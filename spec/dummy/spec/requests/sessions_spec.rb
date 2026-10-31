require "rails_helper"

RSpec.describe "Signing in with the demo", type: :request do
  it "offers the demo's buttons instead of listing its books" do
    Organization.create!(name: "Acme", currency: "AUD")
    Organization.create!(name: Demo::Seeder::NAME, currency: "USD")
    Organization.create!(name: Demo::EuroSeeder::NAME, currency: "EUR")
    Organization.create!(name: Demo::PesoSeeder::NAME, currency: "PHP")

    get new_session_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Acme (AUD)", "Open the demo books (Demo Co)", "Open the euro demo books (Demo GmbH)", "Open the peso demo books (Demo Pilipinas Inc.)")
    expect(response.body).not_to include("Demo Co (USD)", "Demo GmbH (EUR)", "Demo Pilipinas Inc. (PHP)")
  end
end
