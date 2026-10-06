require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Authorization", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:allowed) { %i[read] }
  let(:asked) { [] }

  before do
    sign_in_as(organization)
    TudlaAccounting::AccountsCreator.call([ { code: "1000", name: "Cash", category: "asset" }, { code: "3000", name: "Capital", category: "equity" } ], organization)
    TudlaAccounting.configuration.authorize = lambda do |controller, permission|
      asked << [ controller.class.name, permission ]
      allowed.include?(permission)
    end
  end

  def page = CGI.unescapeHTML(response.body)
  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)

  let(:draft) do
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: Time.zone.local(2026, 3, 1))
    entry.details.build(account: account("1000"), tally: :debit, amount_cents: 100, currency: "AUD", organization: organization)
    entry.details.build(account: account("3000"), tally: :credit, amount_cents: 100, currency: "AUD", organization: organization)
    entry.tap(&:save!)
  end

  context "when only reading is allowed" do
    it "shows the books without the actions, and refuses the actions" do
      get routes.entry_path(draft)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(">Post<", ">Edit<", "Delete")
      expect(css_select("nav .tc-nav-link").map(&:text)).not_to include("Setup")
      get routes.accounts_path
      expect(response.body).not_to include("New account")
      get routes.periods_path
      expect(response.body).not_to include("New financial year")

      post routes.post_entry_path(draft)
      expect(response).to have_http_status(:forbidden)
      expect(page).to include("You can't post, reverse or apply entries.")
      expect(draft.reload).to be_draft

      { routes.new_entry_path => "You can't record entries or change accounts.", routes.setup_path => "Only an administrator can change periods or setup.",
        routes.new_period_path => "Only an administrator" }.each do |path, message|
        get path
        expect(response).to have_http_status(:forbidden)
        expect(page).to include(message, %(href="#{routes.root_path}"))
      end
    end

    it "asks once per permission on a page" do
      get routes.entry_path(draft)
      expect(asked.count { |_name, permission| permission == :post }).to eq(1)
      expect(asked.first).to eq([ "TudlaAccounting::EntriesController", :read ])
    end
  end

  context "when recording but not posting is allowed" do
    let(:allowed) { %i[read record] }

    it "lets drafts be written but not posted" do
      get routes.entry_path(draft)
      expect(response.body).to include(">Edit<")
      expect(response.body).not_to include(">Post<")
      get routes.edit_entry_path(draft)
      expect(response).to have_http_status(:ok)
    end
  end

  context "when everything is allowed" do
    let(:allowed) { %i[read record post administer] }

    it "shows and allows every action" do
      get routes.entry_path(draft)
      expect(response.body).to include(">Post<", ">Edit<")
      get routes.period_path(year)
      expect(response.body).to include("Close")
      post routes.post_entry_path(draft)
      expect(draft.reload).to be_posted
    end
  end

  it "refuses the books altogether without read access, pointing back to the app" do
    TudlaAccounting.configuration.authorize = ->(_controller, _permission) { false }
    get routes.root_path
    expect(response).to have_http_status(:forbidden)
    expect(page).to include("You don't have access to these books.", %(href="#{Rails.application.routes.url_helpers.root_path}"))
  end

  it "only knows the four permissions" do
    expect { Class.new(TudlaAccounting::ApplicationController) { permits :delete, only: :destroy } }
      .to raise_error(ArgumentError, "unknown permission :delete")
  end
end
