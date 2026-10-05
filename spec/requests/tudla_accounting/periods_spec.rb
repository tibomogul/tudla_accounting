require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "Financial years", type: :request do
  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, currency: "AUD") }
  let(:this_year) { Date.current.year }

  before { sign_in_as(organization) }

  def years = TudlaAccounting::Period.roots.where(organization: organization)

  it "invites creating the first year" do
    get routes.periods_path
    expect(response.body).to include("No financial years yet", routes.new_period_path)
  end

  it "lists the organization's years, newest first, marking the current one" do
    TudlaAccounting::PeriodCreator.call(organization, this_year - 1)
    TudlaAccounting::PeriodCreator.call(organization, this_year)
    TudlaAccounting::PeriodCreator.call(create(:organization), this_year + 1)

    get routes.periods_path

    rows = css_select("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
    expect(rows).to eq([ [ this_year.to_s, "1 Jan #{this_year}", "31 Dec #{this_year}", "12", "Current" ],
                         [ (this_year - 1).to_s, "1 Jan #{this_year - 1}", "31 Dec #{this_year - 1}", "12", "" ] ])
  end

  describe "a year" do
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, this_year) }

    it "shows its months and how many lines were posted in each" do
      cash = create(:tudla_accounting_account, category: :asset, organization: organization)
      capital = create(:tudla_accounting_account, category: :equity, organization: organization)
      entry = build(:tudla_accounting_entry, organization: organization, transacted_at: Time.zone.local(this_year, 3, 4))
      entry.details.build(account: cash, tally: :debit, amount_cents: 100, currency: "AUD", organization: organization)
      entry.details.build(account: capital, tally: :credit, amount_cents: 100, currency: "AUD", organization: organization)
      entry.save!
      entry.post(entry.transacted_at)

      get routes.period_path(year)

      rows = css_select("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
      expect(rows.size).to eq(12)
      expect(rows[2]).to eq([ "Mar #{this_year}", "1 Mar #{this_year}", "31 Mar #{this_year}", "2" ])
      expect(response.body).to include("Months cover the whole year")
      expect(response.body).not_to include("Delete year")
    end

    it "flags months that leave gaps" do
      year.children.order(:from_date).last.destroy!
      get routes.period_path(year)
      expect(response.body).to include("Months leave gaps or overlap")
    end

    it "is not shown for another organization, nor are months shown as years" do
      get routes.period_path(TudlaAccounting::PeriodCreator.call(create(:organization), this_year))
      expect(response).to have_http_status(:not_found)

      get routes.period_path(year.children.first)
      expect(response).to have_http_status(:not_found)
    end

    it "can be deleted while nothing is posted in it" do
      get routes.period_path(year)
      expect(response.body).to include("Delete year")

      expect { delete routes.period_path(year) }.to change(TudlaAccounting::Period, :count).by(-13)
      expect(response).to redirect_to(routes.periods_path)
      expect(flash[:notice]).to eq("Financial year #{this_year} was deleted.")
    end

    it "cannot be deleted once something is posted in it" do
      account = create(:tudla_accounting_account, organization: organization)
      TudlaAccounting::Balance.get(account, year.children.first)

      expect { delete routes.period_path(year) }.not_to change(TudlaAccounting::Period, :count)
      expect(response).to redirect_to(routes.period_path(year))
      expect(flash[:alert]).to eq("A year with postings can't be deleted.")
    end
  end

  describe "creating" do
    it "starts with this calendar year" do
      get routes.new_period_path
      expect(css_select("#year_year").first["value"]).to eq(this_year.to_s)
      expect(css_select("#year_start_month option[selected]").text).to eq("January")
    end

    it "creates a calendar year with its months" do
      expect { post routes.periods_path, params: { year: { year: this_year, start_month: 1, start_day: 1 } } }
        .to change { years.count }.by(1)

      expect(response).to redirect_to(routes.period_path(years.last))
      expect(flash[:notice]).to eq("Financial year #{this_year} was created.")
    end

    it "creates a fiscal year" do
      post routes.periods_path, params: { year: { year: this_year, start_month: 7, start_day: 1 } }
      expect(flash[:notice]).to eq("Financial year 1 Jul #{this_year} – 30 Jun #{this_year + 1} was created.")
    end

    it "refuses an overlapping year or an invalid start" do
      TudlaAccounting::PeriodCreator.call(organization, this_year)

      post routes.periods_path, params: { year: { year: this_year, start_month: 7, start_day: 1 } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("The year overlaps an existing financial year")

      post routes.periods_path, params: { year: { year: this_year + 1, start_month: 1, start_day: 31 } }
      expect(response.body).to include("Start day must be between 1 and 28")
      expect(css_select("#year_start_day").first["value"]).to eq("31")
    end

    it "reports a year that could not be saved" do
      allow(TudlaAccounting::PeriodCreator).to receive(:call).and_return(nil)
      post routes.periods_path, params: { year: { year: this_year, start_month: 1, start_day: 1 } }
      expect(response.body).to include("The year could not be created")
    end
  end
end
