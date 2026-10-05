require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Dashboard", type: :request do
  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme Pty Ltd", currency: "AUD") }

  def stat_values = css_select(".tc-stat-value").map { |node| node.text.strip }

  context "with an organization signed in" do
    before { sign_in_as(organization) }

    it "shows the organization's books in the engine layout" do
      create_list(:tudla_accounting_account, 2, organization: organization)
      TudlaAccounting::PeriodCreator.call(organization, Date.current.year)

      get routes.root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<title>Dashboard · Accounting</title>", "Acme Pty Ltd", "kept in AUD")
      expect(response.body).to include('aria-current="page"', %(href="#{Rails.application.routes.url_helpers.root_path}"))
      expect(response.body).to include('import "tudla_accounting/application"')
      expect(stat_values.first(3)).to eq(%w[2 1 0])
    end

    it "counts only the organization's own records" do
      other = create(:organization)
      create_list(:tudla_accounting_account, 3, organization: other)
      TudlaAccounting::PeriodCreator.call(other, Date.current.year)

      get routes.root_path

      expect(stat_values.first(2)).to eq(%w[0 0])
      expect(response.body).to include("None open today")
    end
  end

  it "refuses to show any books without an organization" do
    get routes.root_path

    expect(response).to have_http_status(:forbidden)
    expect(response.body).to include("No organization selected")
    expect(css_select("nav .tc-nav-link").map(&:text)).to eq([ "Back to app ↗" ])
  end

  context "when the host app has not configured current_organization" do
    include_context "with isolated TudlaAccounting configuration"

    it "says what to configure" do
      TudlaAccounting.configuration.current_organization = nil
      expect { get routes.root_path }.to raise_error(TudlaAccounting::ConfigurationError, /current_organization/)
    end
  end
end
