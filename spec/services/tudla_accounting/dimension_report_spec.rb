require "rails_helper"

RSpec.describe "Reporting dimensions", type: :service do
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let!(:department) { TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department") }
  let!(:sales_team) { department.dimension_values.create!(code: "SALES", name: "Sales") }
  let!(:engineering) { department.dimension_values.create!(code: "ENG", name: "Engineering") }
  let!(:project) { TudlaAccounting::Dimension.create!(organization: organization, code: "PROJ", name: "Project") }
  let!(:apollo) { project.dimension_values.create!(code: "APOLLO", name: "Apollo") }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Bank", category: "asset" }, { code: "4000", name: "Sales", category: "income" },
      { code: "4090", name: "Returns", category: "income", contra_account: "4000" }, { code: "6000", name: "Wages", category: "expense" }
    ], organization)
  end

  def book(on, details)
    entry = TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "Entry",
                                                         transacted_at: on.iso8601, details: details)
    entry.post(entry.transacted_at)
    entry
  end

  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def tags(entry) = entry.details.map { |d| [ d.account.code, d.tags.map { |tag| tag.dimension_value.label }.sort ] }

  it "tags lines with one value of each dimension, and keeps the tags on a reversal" do
    entry = book(Time.zone.local(2026, 3, 1), [ { account_code: "1000", amount: "AUD 500.00" },
                                                { account_code: "4000", amount: "AUD 500.00", dimensions: { "DEPT" => "SALES", "PROJ" => "APOLLO" } } ])
    expect(tags(entry)).to contain_exactly([ "1000", [] ], [ "4000", [ "Department: Sales", "Project: Apollo" ] ])
    sale = entry.details.find { |d| d.account.code == "4000" }
    expect(sale.dimension_value_for(department)).to eq(sales_team)
    expect(entry.details.find { |d| d.account.code == "1000" }.dimension_value_for(department)).to be_nil

    reversal = entry.reverse!(on: Date.new(2026, 3, 2))
    expect(tags(reversal)).to contain_exactly([ "1000", [] ], [ "4000", [ "Department: Sales", "Project: Apollo" ] ])
  end

  it "refuses unknown dimensions or values, two values of one dimension, and another organization's value" do
    expect { book(Time.zone.local(2026, 3, 1), [ { account_code: "1000", amount: "AUD 1.00" }, { account_code: "4000", amount: "AUD 1.00", dimensions: { "AREA" => "X" } } ]) }
      .to raise_error(ArgumentError, "invalid dimension: AREA")
    expect { book(Time.zone.local(2026, 3, 1), [ { account_code: "1000", amount: "AUD 1.00" }, { account_code: "4000", amount: "AUD 1.00", dimensions: { "DEPT" => "HR" } } ]) }
      .to raise_error(ArgumentError, "invalid Department value: HR")

    line = TudlaAccounting::Detail.new(organization: organization, account: TudlaAccounting::Account.find_by(code: "4000", organization: organization), tally: :credit, amount_cents: 1)
    line.tags.build(dimension_value: sales_team)
    line.tags.build(dimension_value: engineering)
    expect(line.errors.tap { line.valid? }[:tags]).to eq([ "can only have one value of each dimension" ])

    other = TudlaAccounting::Dimension.create!(organization: create(:organization), code: "DEPT", name: "Department").dimension_values.create!(code: "X", name: "X")
    tag = TudlaAccounting::DetailTag.new(detail: line, dimension_value: other)
    expect(tag.errors.tap { tag.valid? }[:dimension_value]).to eq([ "must belong to the same organization" ])
  end

  it "keeps codes unique, labels things, and knows what is in use" do
    expect(TudlaAccounting::Dimension.new(organization: organization, code: "DEPT", name: "Again")).not_to be_valid
    expect(TudlaAccounting::DimensionValue.new(dimension_id: department.id, code: "SALES", name: "Again")).not_to be_valid
    expect(department.label).to eq("Department (DEPT)")
    expect([ department.used?, sales_team.used? ]).to eq([ false, false ])
    book(Time.zone.local(2026, 3, 1), [ { account_code: "1000", amount: "AUD 1.00" }, { account_code: "4000", amount: "AUD 1.00", dimensions: { "DEPT" => "SALES" } } ])
    expect([ department.used?, sales_team.used?, engineering.used? ]).to eq([ true, true, false ])
    expect(TudlaAccounting::AuditEvent.where(action: %w[dimension.created dimension_value.created]).count).to eq(5)
    department.update!(name: "Team")
    expect(TudlaAccounting::AuditEvent.last).to have_attributes(action: "dimension.updated", details: { "changes" => { "name" => [ "Department", "Team" ] } })
    sales_team.update!(active: false)
    expect(TudlaAccounting::AuditEvent.last).to have_attributes(action: "dimension_value.updated", subject_label: "Team: Sales")
  end

  describe "profit and loss by dimension" do
    def report(dimension = department, from: Time.zone.local(2026, 1, 1), thru: Time.zone.local(2026, 3, 31).end_of_day)
      TudlaAccounting::DimensionReport.call(organization, dimension, from: from, thru: thru)
    end

    before do
      book(Time.zone.local(2026, 2, 1), [ { account_code: "1000", amount: "AUD 1000.00" }, { account_code: "4000", amount: "AUD 1000.00", dimensions: { "DEPT" => "SALES" } } ])
      book(Time.zone.local(2026, 2, 2), [ { account_code: "1000", amount: "AUD 200.00" }, { account_code: "4000", amount: "AUD 200.00" } ])
      book(Time.zone.local(2026, 2, 3), [ { account_code: "4090", amount: "AUD 50.00", dimensions: { "DEPT" => "SALES" } }, { account_code: "1000", amount: "AUD -50.00" } ])
      book(Time.zone.local(2026, 2, 4), [ { account_code: "6000", amount: "AUD 300.00", dimensions: { "DEPT" => "ENG" } }, { account_code: "1000", amount: "AUD -300.00" } ])
      book(Time.zone.local(2026, 4, 1), [ { account_code: "6000", amount: "AUD 999.00", dimensions: { "DEPT" => "ENG" } }, { account_code: "1000", amount: "AUD -999.00" } ])
    end

    it "breaks income and expenses down by value, with what isn't tagged" do
      result = report
      expect(result[:columns]).to eq([ engineering, sales_team, nil ])
      expect(result[:income].map { |row| [ row[:account].code, row[:amounts].values, row[:total] ] })
        .to eq([ [ "4000", [ aud(0), aud(1000), aud(200) ], aud(1200) ], [ "4090", [ aud(0), aud(-50), aud(0) ], aud(-50) ] ])
      expect(result[:expense].map { |row| [ row[:account].code, row[:amounts].values ] }).to eq([ [ "6000", [ aud(300), aud(0), aud(0) ] ] ])
      expect(result[:totals][:net_profit]).to eq(engineering => aud(-300), sales_team => aud(950), nil => aud(200), total: aud(850))
    end

    it "leaves out the untagged column when everything is tagged, and inactive values without postings" do
      engineering.update!(active: false)
      april = report(from: Time.zone.local(2026, 4, 1), thru: Time.zone.local(2026, 4, 30).end_of_day)
      expect(april[:columns]).to eq([ engineering, sales_team ])
      expect(report(project)[:columns]).to eq([ apollo, nil ])

      march = report(from: Time.zone.local(2026, 3, 1), thru: Time.zone.local(2026, 3, 31).end_of_day)
      expect(march[:columns]).to eq([ sales_team ])
    end

    it "refuses another organization's dimension" do
      other = TudlaAccounting::Dimension.create!(organization: create(:organization), code: "X", name: "X")
      expect { report(other) }.to raise_error(ArgumentError, "The dimension belongs to another organization")
    end
  end
end
