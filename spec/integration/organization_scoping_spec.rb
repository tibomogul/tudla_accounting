require "rails_helper"
require_relative "../support/sign_in"
require_relative "../support/configuration"

# Within a request to the engine's pages or API, lookups of the engine's models find only
# the request's organization's rows, even without organization_scope (OrganizationOwned).
RSpec.describe "Lookups limited to the current organization", type: :request do
  include_context "with isolated TudlaAccounting configuration"

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:acme) { create(:organization, name: "Acme", currency: "AUD") }
  let(:globex) { create(:organization, name: "Globex", currency: "AUD") }
  let!(:ours) { TudlaAccounting::Contact.create!(organization: acme, name: "Initech", kind: "customer") }
  let!(:theirs) { TudlaAccounting::Contact.create!(organization: globex, name: "Umbrella", kind: "customer") }

  after { TudlaAccounting::Current.reset }

  it "covers every engine model with an organization" do
    Rails.application.eager_load!
    owned = TudlaAccounting::ApplicationRecord.descendants.reject(&:abstract_class?).select { |model| model.column_names.include?("organization_id") }

    expect(owned).not_to be_empty
    expect(owned.reject { |model| model.include?(TudlaAccounting::OrganizationOwned) }).to be_empty
  end

  it "finds only the current organization's rows, and starts new records in it" do
    TudlaAccounting.with_organization(acme) do
      expect(TudlaAccounting::Contact.all).to contain_exactly(ours)
      expect { TudlaAccounting::Contact.find(theirs.id) }.to raise_error(ActiveRecord::RecordNotFound)
      expect(TudlaAccounting::Contact.new(name: "Hooli").organization).to eq(acme)
      expect(TudlaAccounting::Contact.unscoped.where(id: theirs.id)).to contain_exactly(theirs)
      expect(TudlaAccounting.with_organization(nil) { TudlaAccounting::Contact.all.to_a }).to include(ours, theirs)
    end
    expect(TudlaAccounting::Contact.all).to include(ours, theirs)
  end

  it "is set for each request to the engine's pages, and unset after" do
    sign_in_as(acme)
    seen = nil
    allow_any_instance_of(TudlaAccounting::ContactsController).to receive(:index).and_wrap_original do |original|
      seen = [ TudlaAccounting::Current.organization, TudlaAccounting::Contact.pluck(:id) ]
      original.call
    end

    get routes.contacts_path

    expect(response).to have_http_status(:ok)
    expect(seen).to eq([ acme, [ ours.id ] ])
    expect(TudlaAccounting::Current.organization).to be_nil
  end

  it "is set for each API request, from its token" do
    secret = TudlaAccounting::ApiToken.issue!(organization: globex, name: "Shop", permissions: %w[read]).last
    seen = nil
    allow_any_instance_of(TudlaAccounting::Api::V1::ContactsController).to receive(:index).and_wrap_original do |original|
      seen = [ TudlaAccounting::Current.organization, TudlaAccounting::Contact.pluck(:id) ]
      original.call
    end

    get routes.api_v1_contacts_path, headers: { "Authorization" => "Bearer #{secret}" }

    expect(response).to have_http_status(:ok)
    expect(seen).to eq([ globex, [ theirs.id ] ])
  end
end
