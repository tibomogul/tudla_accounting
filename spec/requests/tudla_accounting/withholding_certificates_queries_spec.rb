require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "The tax certificates page's queries", type: :request do
  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Bayanihan Corp.", currency: "PHP") }
  let(:code) { TudlaAccounting::WithholdingCode.create!(organization: organization, code: "WC160", name: "Services", rate: "0.02", creditable_account: account("1200")) }

  before do
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, Date.current.year)
    TudlaAccounting::AccountsCreator.call([ { code: "1010", name: "Bank", category: "asset" }, { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "1200", name: "Creditable tax", category: "asset" } ], organization)
  end

  def account(number) = TudlaAccounting::Account.find_by!(organization: organization, code: number)

  def add_payments(count)
    customer = TudlaAccounting::Contact.create!(organization: organization, name: "Customer #{SecureRandom.hex(3)}", kind: "customer")
    count.times do
      TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: customer, account: account("1010"), paid_on: Date.new(Date.current.year, 2, 3), amount_cents: 9_800_00,
                                       withholdings: [ { code: code, withheld_cents: 200_00 } ])
    end
  end

  def queries_for_page
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:sql].start_with?("SAVEPOINT", "RELEASE") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get routes.withholding_certificates_path(show: "all") }
    expect(response).to have_http_status(:ok)
    count
  end

  it "doesn't grow with the rows shown" do
    add_payments(2)
    queries_for_page # settles what the first request caches
    few = queries_for_page
    add_payments(6)
    expect(css_select("[data-certificate-row]").size).to eq(2)
    expect(queries_for_page).to be <= few + 1 # a second customer in the filter is one row, not a query each; allow for its group
    expect(css_select("[data-certificate-row]").size).to eq(8)
  end
end
