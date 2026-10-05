require "rails_helper"

RSpec.describe TudlaAccounting::ApplicationController, type: :controller do
  render_views

  controller do
    def index
      @account = organization_scope(TudlaAccounting::Account).find(params[:id])
      render plain: @account.code
    end
  end

  let(:organization) { create(:organization, name: "Acme") }

  before do
    routes.draw { get "anonymous" => "tudla_accounting/application#index" }
    session[:organization_id] = organization.id
  end

  it "inherits from the host's controller" do
    expect(described_class.superclass).to eq(::ApplicationController)
  end

  it "finds the organization's own records" do
    account = create(:tudla_accounting_account, code: "1000", organization: organization)
    get :index, params: { id: account.id }
    expect(response.body).to eq("1000")
  end

  it "shows not found for another organization's record" do
    stranger = create(:tudla_accounting_account, organization: create(:organization))

    get :index, params: { id: stranger.id }

    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("Not found", "doesn't exist in Acme's books")
  end
end
