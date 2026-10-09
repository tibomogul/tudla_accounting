require "rails_helper"

RSpec.describe "Demo sign-in", type: :request do
  it "seeds Demo Co and opens its books" do
    post demo_session_path

    expect(response).to redirect_to(TudlaAccounting::Engine.routes.url_helpers.root_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Demo Co")
  end
end
