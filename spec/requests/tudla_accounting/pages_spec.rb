require "rails_helper"

RSpec.describe "TudlaAccounting pages", type: :request do
  describe "GET the engine root" do
    it "renders the landing page in the engine layout, linking back to the host app" do
      get TudlaAccounting::Engine.routes.url_helpers.root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<title>TudlaAccounting</title>")
      expect(response.body).to include(%(href="#{Rails.application.routes.url_helpers.root_path}"))
    end
  end
end
