require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "Balance check", type: :request do
  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "USD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    sign_in_as(organization)
    TudlaAccounting::AccountsCreator.call([ { code: "1000", name: "Cash", category: "asset" }, { code: "3100", name: "Capital", category: "equity" } ], organization)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: Time.zone.local(2026, 2, 1))
    entry.details.build(account: account("1000"), tally: :debit, amount_cents: 100_00, currency: "USD", organization: organization)
    entry.details.build(account: account("3100"), tally: :credit, amount_cents: 100_00, currency: "USD", organization: organization)
    entry.save!
    entry.post(entry.transacted_at)
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def rows = css_select("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }

  it "is offered on the setup page" do
    get routes.setup_path
    expect(css_select("a[href='#{routes.setup_balances_path}']").text).to eq("Check balances")
  end

  it "says when every balance agrees" do
    get routes.setup_balances_path
    expect(response.body).to include("Every stored balance agrees with the posted entries.")
    expect(css_select("form[action='#{routes.setup_balances_path}']")).to be_empty
  end

  it "lists the differences, and rebuilds the balances on request" do
    TudlaAccounting::Balance.find_by(account: account("1000"), period: year).update_columns(ending_amount_cents: 1)
    TudlaAccounting::Balance.find_by(account: account("3100"), period: year).delete

    get routes.setup_balances_path
    expect(response.body).to include("2 differences between the stored balances")
    expect(rows).to eq([ [ "Year 2026", "1000 Cash", "Closing", "0.01", "100.00" ], [ "Year 2026", "3100 Capital", "Not stored", "—", "100.00" ] ])
    expect(css_select("form[action='#{routes.setup_balances_path}'] button").text).to eq("Rebuild balances")

    post routes.setup_balances_path
    expect(response).to redirect_to(routes.setup_balances_path)
    expect(flash[:notice]).to eq("Corrected 2 balances from the posted entries.")
    follow_redirect!
    expect(response.body).to include("Every stored balance agrees")

    post routes.setup_balances_path
    expect(flash[:notice]).to eq("The balances already agree with the posted entries.")
  end
end
