require "rails_helper"

RSpec.describe "Signing in with the demo", type: :request do
  it "offers the demo's button instead of listing Demo Co" do
    Organization.create!(name: "Acme", currency: "AUD")
    Organization.create!(name: Demo::Seeder::NAME, currency: "USD")

    get new_session_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Acme (AUD)", "Open the demo books (Demo Co)")
    expect(response.body).not_to include("Demo Co (USD)")
  end
end
