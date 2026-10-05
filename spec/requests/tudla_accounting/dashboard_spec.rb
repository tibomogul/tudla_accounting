require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"
require_relative "../../support/entry_sources"

RSpec.describe "Dashboard", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme Pty Ltd", currency: "AUD") }

  def stat(name) = css_select("[data-stat=#{name}]").first.text.squish
  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)

  def post_entry(debit, credit, cents, on, draft: false, **attrs)
    entry = build(:tudla_accounting_entry, organization: organization, transacted_at: on, particulars: "#{debit} from #{credit}", **attrs)
    entry.details.build(account: account(debit), tally: :debit, amount_cents: cents, currency: "AUD", organization: organization)
    entry.details.build(account: account(credit), tally: :credit, amount_cents: cents, currency: "AUD", organization: organization)
    entry.save!
    entry.post(on) unless draft
    entry
  end

  context "with an organization signed in" do
    before { sign_in_as(organization) }

    it "shows the organization's books in the engine layout" do
      get routes.root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<title>Dashboard · Accounting</title>", "Acme Pty Ltd", "kept in AUD")
      expect(response.body).to include('aria-current="page"', %(href="#{Rails.application.routes.url_helpers.root_path}"))
      expect(response.body).to include('import "tudla_accounting/application"')
    end

    it "guides a new organization through getting started, with no figures yet" do
      get routes.root_path

      expect(response.body).to include("Getting started", "Create a financial year", "Load a chart of accounts")
      expect([ stat("profit"), stat("receivables"), stat("drafts") ]).to eq([ "—", "0.00", "0" ])
      expect(response.body).to include("No period covers today", "No entries yet.")
    end

    context "with books under way" do
      include_context "with entry source models"

      before do
        TudlaAccounting::PeriodCreator.call(organization, 2026)
        TudlaAccounting::AccountsCreator.call([
          { code: "1010", name: "Cash", category: "asset" }, { code: "1100", name: "Receivables", category: "asset" },
          { code: "2100", name: "Payables", category: "liability" }, { code: "4000", name: "Sales", category: "income" },
          { code: "6000", name: "Rent", category: "expense" }
        ], organization)
        post_entry("1100", "4000", 500_00, Time.zone.local(2026, 2, 1), source: Invoice.create!(due_date: Time.zone.local(2026, 3, 1)))
        post_entry("1100", "4000", 200_00, Time.zone.local(2026, 4, 1), source: Invoice.create!(due_date: Time.zone.local(2026, 5, 1)))
        post_entry("6000", "2100", 120_00, Time.zone.local(2026, 4, 2), source: Bill.create!(due_date: Time.zone.local(2026, 5, 2)))
        post_entry("6000", "1010", 30_00, Time.zone.local(2026, 4, 3), draft: true)
      end

      it "shows the year's profit, what is owed each way, drafts and recent entries" do
        travel_to(Time.zone.local(2026, 4, 15)) { get routes.root_path }

        expect(response.body).not_to include("Getting started")
        expect([ stat("profit"), stat("receivables"), stat("payables"), stat("drafts") ]).to eq([ "580.00", "700.00", "120.00", "1" ])
        expect(response.body).to include("To 30 Apr 2026", "500.00 overdue", "0.00 overdue")
        expect(css_select("table tbody tr").size).to eq(4)
        expect(response.body).to include("5 accounts · 1 financial year · current period Apr 2026")
      end

      it "leaves out other organizations' figures" do
        other = create(:organization)
        TudlaAccounting::PeriodCreator.call(other, 2026)
        sign_in_as(other)
        travel_to(Time.zone.local(2026, 4, 15)) { get routes.root_path }
        expect([ stat("profit"), stat("receivables"), stat("drafts") ]).to eq([ "0.00", "0.00", "0" ])
      end
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
