require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "API tokens", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme") }
  let(:permissions) { %i[read record post administer] }

  before do
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
  end

  it "issues a token, showing its secret once, lists it, and revokes it" do
    get routes.setup_path
    expect(response.body).to include("Manage API tokens")
    get routes.api_tokens_path
    expect(response.body).to include("No tokens yet.")
    get routes.new_api_token_path
    expect(css_select("input[name='api_token[permissions][]'][checked]").map { |box| box["value"] }).to eq(%w[read])

    post routes.api_tokens_path, params: { api_token: { name: "Shop", permissions: %w[read record], expires_on: "2099-01-31" } }
    expect(response).to have_http_status(:created)
    expect(response.headers["Cache-Control"]).to include("no-store")
    secret = css_select("input[data-secret]").first["value"]
    token = TudlaAccounting::ApiToken.sole
    expect(response.body).to include("It can read and record, until 31 Jan 2099")
    expect(flash[:notice]).to be_nil

    get routes.api_tokens_path
    expect(response.body).not_to include(secret)
    expect(css_select("tr[data-token]").first.text.squish).to include("Shop", token.masked, "read, record", "by Demo user", "Never", "31 Jan 2099", "Active")

    expect(TudlaAccounting::ApiToken.authenticate(secret)).to eq(token)
    get routes.api_tokens_path
    expect(css_select("tr[data-token]").first.text).not_to include("Never")

    post routes.revoke_api_token_path(token)
    expect(flash[:notice]).to eq("Shop revoked: it no longer works.")
    post routes.revoke_api_token_path(token)
    expect(flash[:alert]).to eq("This token is revoked already")
    get routes.api_tokens_path
    expect(css_select("tr[data-token]").first.text).to include("Revoked")

    get routes.activity_path(kind: "api_token")
    expect(response.body).to include("Issued", "API token Shop", "(read and record)", "Revoked")
  end

  it "says what's missing" do
    post routes.api_tokens_path, params: { api_token: { name: "" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Name can&#39;t be blank", "Permissions choose at least one")
  end

  it "shows an expired token as expired" do
    TudlaAccounting::ApiToken.issue!(organization: organization, name: "Old", permissions: %w[read], expires_on: Date.new(2020, 1, 1))
    get routes.api_tokens_path
    expect(css_select("tr[data-token]").first.text).to include("Expired")
  end

  context "without the administer permission" do
    let(:permissions) { %i[read record post] }

    it "keeps tokens out of reach" do
      get routes.api_tokens_path
      expect(response).to have_http_status(:forbidden)
      post routes.api_tokens_path, params: { api_token: { name: "Sneaky", permissions: %w[administer] } }
      expect(response).to have_http_status(:forbidden)
      expect(TudlaAccounting::ApiToken.count).to eq(0)
    end
  end

  it "keeps another organization's tokens apart" do
    theirs, = TudlaAccounting::ApiToken.issue!(organization: create(:organization), name: "Theirs", permissions: %w[read])
    post routes.revoke_api_token_path(theirs)
    expect(response).to have_http_status(:not_found)
    expect(theirs.reload).not_to be_revoked
  end
end
