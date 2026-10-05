require "rails_helper"

# Scoping to the organization and the not-found page are covered through real pages in
# spec/requests (e.g. another organization's account in accounts_spec).
RSpec.describe TudlaAccounting::ApplicationController, type: :controller do
  it "inherits from the host's controller" do
    expect(described_class.superclass).to eq(::ApplicationController)
  end
end
