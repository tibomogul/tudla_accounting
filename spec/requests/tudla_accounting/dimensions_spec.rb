require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "Dimensions", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, currency: "AUD") }

  before { sign_in_as(organization) }

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def department = TudlaAccounting::Dimension.find_by!(organization: organization, code: "DEPT")
  def value(code) = department.dimension_values.find_by!(code: code)

  describe "managing them" do
    it "adds a dimension and its values, edits and deactivates them, and logs it" do
      get routes.dimensions_path
      expect(response.body).to include("No dimensions yet.")
      get routes.new_dimension_path
      expect(css_select("#dimension_code")).to be_present

      post routes.dimensions_path, params: { dimension: { code: "DEPT", name: "Department", active: "1" } }
      expect(flash[:notice]).to eq("Dimension Department (DEPT) was added. Add its values next.")
      post routes.dimension_dimension_values_path(department), params: { dimension_value: { code: "SALES", name: "Sales", active: "1" } }
      expect(flash[:notice]).to eq("Department: Sales was added.")
      get routes.new_dimension_dimension_value_path(department)
      expect(response.body).to include("New department value")

      patch routes.dimension_dimension_value_path(department, value("SALES")), params: { dimension_value: { name: "Sales team", active: "0" } }
      expect(flash[:notice]).to eq("Department: Sales team was saved.")
      patch routes.dimension_path(department), params: { dimension: { name: "Team" } }
      expect(flash[:notice]).to eq("Dimension Team (DEPT) was saved.")

      get routes.dimensions_path
      expect(css_select("section h2").map { |h| h.text.squish }).to eq([ "Team (DEPT)" ])
      expect(css_select("section tbody tr").first.text.squish).to eq("SALES Sales team Inactive")

      get routes.activity_path(kind: "dimension_value")
      expect(css_select("tbody td:last-child").map { |cell| cell.text.squish }).to eq([ "Changed Department: Sales team: name, active", "Added Department: Sales" ]) # as labelled at the time
      get routes.activity_path(kind: "dimension")
      expect(css_select("tbody td:last-child").map { |cell| cell.text.squish }).to eq([ "Changed Team (DEPT): name", "Added the dimension Department (DEPT)" ])
      expect(css_select("tbody a").map { |link| link["href"] }).to include(routes.edit_dimension_path(department))
    end

    it "shows what is wrong" do
      post routes.dimensions_path, params: { dimension: { code: "", name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Code can&#39;t be blank")
      TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department")
      patch routes.dimension_path(department), params: { dimension: { name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      post routes.dimension_dimension_values_path(department), params: { dimension_value: { code: "", name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      department.dimension_values.create!(code: "X", name: "X")
      patch routes.dimension_dimension_value_path(department, value("X")), params: { dimension_value: { name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      get routes.edit_dimension_dimension_value_path(department, value("X"))
      expect(response).to have_http_status(:ok)
    end

    it "refuses another organization's dimension" do
      other = TudlaAccounting::Dimension.create!(organization: create(:organization), code: "X", name: "X")
      get routes.edit_dimension_path(other)
      expect(response).to have_http_status(:not_found)
    end
  end

  context "with a department dimension and a year" do
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

    before do
      TudlaAccounting::AccountsCreator.call([ { code: "1000", name: "Bank", category: "asset" }, { code: "4000", name: "Sales", category: "income" },
                                              { code: "6000", name: "Wages", category: "expense" } ], organization)
      dimension = TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department")
      dimension.dimension_values.create!(code: "SALES", name: "Sales")
      dimension.dimension_values.create!(code: "ENG", name: "Engineering")
      dimension.dimension_values.create!(code: "OLD", name: "Old", active: false)
    end

    def save(lines, entry: nil)
      attributes = { particulars: "Entry", transacted_at: "2026-03-02", lines: lines.each_with_index.to_h { |line, index| [ index.to_s, line ] } }
      entry ? patch(routes.entry_path(entry), params: { entry: attributes }) : post(routes.entries_path, params: { entry: attributes })
      entry || TudlaAccounting::Entry.order(:id).last
    end

    def tags(entry) = entry.reload.details.map { |d| [ d.account.code, d.tags.map { |tag| tag.dimension_value.code } ] }

    it "tags lines from the entry form, and changes or removes the tags on a draft" do
      get routes.new_entry_path
      template = Nokogiri::HTML(css_select("template").first.inner_html)
      expect(template.css("select[aria-label=Department] option").map(&:text)).to eq([ "—", "Engineering", "Sales" ])

      entry = save([ { account_id: account("1000").id, debit: "100" }, { account_id: account("4000").id, credit: "100", dimensions: { department.id => value("SALES").id } } ])
      expect(tags(entry)).to contain_exactly([ "1000", [] ], [ "4000", [ "SALES" ] ])
      get routes.entry_path(entry)
      expect(css_select("[data-tag]").map { |tag| tag.text.squish }).to eq([ "Department: Sales" ])

      bank, sale = entry.details.sort_by(&:id)
      get routes.edit_entry_path(entry)
      expect(css_select("select[aria-label=Department] option[selected]").map(&:text)).to eq([ "Sales" ])

      save([ { id: bank.id, account_id: account("1000").id, debit: "100", dimensions: { department.id => value("ENG").id } },
             { id: sale.id, account_id: account("4000").id, credit: "100", dimensions: { department.id => value("ENG").id } } ], entry: entry)
      expect(tags(entry)).to contain_exactly([ "1000", [ "ENG" ] ], [ "4000", [ "ENG" ] ])

      save([ { id: bank.id, account_id: account("1000").id, debit: "100", dimensions: { department.id => value("ENG").id } },
             { id: sale.id, account_id: account("4000").id, credit: "100", dimensions: { department.id => "" } } ], entry: entry)
      expect(tags(entry)).to contain_exactly([ "1000", [ "ENG" ] ], [ "4000", [] ])
    end

    it "still offers an inactive value already on the entry" do
      entry = save([ { account_id: account("1000").id, debit: "1" }, { account_id: account("4000").id, credit: "1", dimensions: { department.id => value("OLD").id } } ])
      get routes.edit_entry_path(entry)
      expect(css_select("tbody select[aria-label=Department]").first.css("option").map(&:text)).to eq([ "—", "Engineering", "Old", "Sales" ])
    end

    it "refuses another organization's dimension value" do
      other = TudlaAccounting::Dimension.create!(organization: create(:organization), code: "X", name: "X").dimension_values.create!(code: "Y", name: "Y")
      save([ { account_id: account("1000").id, debit: "1" }, { account_id: account("4000").id, credit: "1", dimensions: { other.dimension_id => other.id } } ])
      expect(response).to have_http_status(:not_found)
    end

    describe "the report" do
      before do
        [ [ "4000", "SALES", 500_00, Time.zone.local(2026, 2, 1) ], [ "6000", "ENG", 120_00, Time.zone.local(2026, 3, 1) ], [ "4000", nil, 80_00, Time.zone.local(2026, 3, 2) ] ].each do |code, tag, cents, at|
          entry = build(:tudla_accounting_entry, organization: organization, transacted_at: at)
          line = entry.details.build(account: account(code), tally: code == "4000" ? :credit : :debit, amount_cents: cents, currency: "AUD", organization: organization)
          line.tags.build(dimension_value: value(tag)) if tag
          entry.details.build(account: account("1000"), tally: code == "4000" ? :debit : :credit, amount_cents: cents, currency: "AUD", organization: organization)
          entry.save!
          entry.post(at)
        end
      end

      def net(column) = css_select("[data-net=#{column}]").first.text.squish

      it "shows the year to date by default, a column per value and what is untagged" do
        travel_to(Time.zone.local(2026, 3, 15)) { get routes.reports_by_dimension_path }
        expect(response.body).to include("Profit and loss by department", "1 Jan 2026 to 31 Mar 2026")
        expect(css_select("thead th").map(&:text)).to eq([ "Account", "Engineering", "Sales", "Untagged", "Total" ])
        expect([ net("ENG"), net("SALES"), net("untagged"), net("total") ]).to eq([ "(120.00)", "500.00", "80.00", "460.00" ])
      end

      it "covers chosen months either way round" do
        get routes.reports_by_dimension_path(dimension_id: department.id, from_id: year.children.order(:from_date).third.id, thru_id: year.children.order(:from_date).second.id)
        expect(response.body).to include("1 Feb 2026 to 31 Mar 2026")
        get routes.reports_by_dimension_path(from_id: year.children.order(:from_date).fifth.id, thru_id: year.children.order(:from_date).fifth.id)
        expect(response.body).to include("Nothing posted.")
      end

      it "refuses another organization's dimension" do
        other = TudlaAccounting::Dimension.create!(organization: create(:organization), code: "X", name: "X")
        get routes.reports_by_dimension_path(dimension_id: other.id)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  it "points to adding a dimension when there are none, and to a year when there is none" do
    get routes.reports_by_dimension_path
    expect(response.body).to include("No dimensions yet.", routes.dimensions_path)
    TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department")
    get routes.reports_by_dimension_path
    expect(response.body).to include("No financial year yet.")
  end
end
