require "rails_helper"

RSpec.describe "tudla_accounting/shared/_pagination", type: :view do
  let(:organization) { create(:organization) }
  let(:scope) { TudlaAccounting::Account.where(organization: organization) }

  before { 5.times { create(:tudla_accounting_account, organization: organization) } }

  def render_page(page, per_page: 2)
    controller.request.path = "/tudla_accounting/accounts"
    controller.request.query_parameters.merge!("q" => "cash")
    render partial: "tudla_accounting/shared/pagination", locals: { paginator: TudlaAccounting::Paginator.new(scope, page: page, per_page: per_page) }
    Nokogiri::HTML(rendered)
  end

  it "links to each page, keeping the query, and marks the current one" do
    html = render_page(2)

    expect(html.css("a.tc-page").map(&:text)).to eq([ "‹ Previous", "1", "2", "3", "Next ›" ])
    expect(html.at_css("a[aria-current='page']").text).to eq("2")
    expect(html.at_css("a.tc-page:last-child")["href"]).to eq("/tudla_accounting/accounts?page=3&q=cash")
  end

  it "disables previous on the first page" do
    expect(render_page(1).at_css("a.tc-page:first-child")["aria-disabled"]).to eq("true")
  end

  it "disables next on the last page" do
    expect(render_page(3).at_css("a.tc-page:last-child")["aria-disabled"]).to eq("true")
  end

  it "shows gaps in long page ranges" do
    expect(render_page(1, per_page: 1).css("span.tc-page").map(&:text)).to eq([ "…" ])
  end

  it "renders nothing for a single page" do
    expect(render_page(1, per_page: 25).text.strip).to be_empty
  end
end
