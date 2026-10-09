require "rails_helper"

# The dummy app's stand-in login, as the engine's specs see it: without the demo.
RSpec.describe "Signing in to the dummy app", type: :request do
  it "lists every organization" do
    create(:organization, name: "Acme", currency: "AUD")
    create(:organization, name: "Globex", currency: "USD")

    get Rails.application.routes.url_helpers.new_session_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Acme (AUD)", "Globex (USD)")
  end
end
