require "rails_helper"

RSpec.describe TudlaAccounting::Paginator do
  let(:organization) { create(:organization) }
  let(:scope) { TudlaAccounting::Account.where(organization: organization).order(:code) }

  before { 7.times { |i| create(:tudla_accounting_account, code: "10#{i}0", organization: organization) } }

  it "returns a page of records" do
    paginator = described_class.new(scope, page: 2, per_page: 3)
    expect(paginator.records.map(&:code)).to eq(%w[1030 1040 1050])
    expect(paginator).to have_attributes(page: 2, total_count: 7, total_pages: 3, previous_page: 1, next_page: 3)
  end

  it "keeps the page within range" do
    expect(described_class.new(scope, page: 9, per_page: 3).page).to eq(3)
    expect(described_class.new(scope, page: nil, per_page: 3)).to have_attributes(page: 1, previous_page: nil)
    expect(described_class.new(scope, page: "-2", per_page: 3).page).to eq(1)
  end

  it "has one page when empty" do
    expect(described_class.new(scope.none, page: 1)).to have_attributes(total_pages: 1, next_page: nil, records: [])
  end

  it "shows a window of page numbers with gaps" do
    paginator = described_class.new(scope, page: 4, per_page: 1)
    expect(paginator.window).to eq([ 1, nil, 3, 4, 5, nil, 7 ])
    expect(described_class.new(scope, page: 1, per_page: 1).window).to eq([ 1, 2, nil, 7 ])
  end

  it "pages an array" do
    paginator = described_class.new((1..7).to_a, page: 3, per_page: 3)
    expect(paginator.records).to eq([ 7 ])
    expect(described_class.new([], page: 1).records).to eq([])
  end
end
