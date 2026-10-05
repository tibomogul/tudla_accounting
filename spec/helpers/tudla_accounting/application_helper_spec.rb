require "rails_helper"

RSpec.describe TudlaAccounting::ApplicationHelper, type: :helper do
  describe "#tc_money" do
    it "formats amounts accounting-style without a symbol" do
      expect(helper.tc_money(Money.from_amount(1234.5, "AUD"))).to eq("1,234.50")
      expect(helper.tc_money(Money.from_amount(1500, "JPY"))).to eq("1,500")
      expect(helper.tc_money(nil)).to eq("")
    end

    it "shows negatives in parentheses" do
      expect(helper.tc_money(Money.from_amount(-80, "AUD"))).to eq('<span class="tc-negative">(80.00)</span>')
    end
  end

  it "#tc_date formats dates and times, and allows nil" do
    expect(helper.tc_date(Date.new(2026, 3, 5))).to eq("5 Mar 2026")
    expect(helper.tc_date(Time.zone.local(2026, 12, 31, 23, 59))).to eq("31 Dec 2026")
    expect(helper.tc_date(nil)).to be_nil
  end

  describe "#tc_badge" do
    it "renders a badge in a tone" do
      expect(helper.tc_badge("AUD")).to eq('<span class="tc-badge">AUD</span>')
      expect(helper.tc_badge("Posted", tone: :success)).to eq('<span class="tc-badge tc-badge-success">Posted</span>')
    end

    it "rejects unknown tones" do
      expect { helper.tc_badge("x", tone: :pink) }.to raise_error(ArgumentError, "Unknown badge tone :pink")
    end
  end

  it "#tc_page_header renders the title, subtitle and actions, and sets the page title" do
    html = helper.tc_page_header("Accounts", subtitle: "Chart of accounts") { helper.link_to("New", "/new", class: "tc-btn") }

    expect(html).to include("<h1", "Accounts", "Chart of accounts", '<a class="tc-btn" href="/new">New</a>')
    expect(helper.content_for(:title)).to eq("Accounts")
    expect(helper.tc_page_header("Plain")).not_to include("flex-wrap gap-2")
  end

  describe "#tc_nav_link" do
    before { allow(helper).to receive(:root_path).and_return("/tudla_accounting/") }

    it "marks the link for the current page or section" do
      allow(helper).to receive(:request).and_return(double(path: "/tudla_accounting/accounts/4"))

      expect(helper.tc_nav_link("Accounts", "/tudla_accounting/accounts")).to include('aria-current="page"')
      expect(helper.tc_nav_link("Dashboard", "/tudla_accounting/")).not_to include("aria-current")
    end
  end

  describe "#tc_field" do
    let(:account) { TudlaAccounting::Account.new }
    let(:form) { ActionView::Helpers::FormBuilder.new(:account, account, helper, {}) }

    it "renders a labelled input with a hint" do
      html = helper.tc_field(form, :name, hint: "Shown on reports", placeholder: "Cash")
      expect(html).to include('<label class="tc-label" for="account_name">Name</label>', 'class="tc-input"', 'placeholder="Cash"', "Shown on reports")
    end

    it "renders a select" do
      html = helper.tc_field(form, :category, as: :select, choices: [ [ "Asset", "asset" ] ], label: "Type")
      expect(html).to include("<select", '<option value="asset">Asset</option>', ">Type</label>")
    end

    it "shows the attribute's errors" do
      account.validate
      html = helper.tc_field(form, :code)
      expect(html).to include("tc-input-error", '<p class="tc-error-text">Code can&#39;t be blank</p>')
    end
  end

  it "#tc_period_label names calendar years and months, and dates other periods" do
    organization = create(:organization)
    year = TudlaAccounting::PeriodCreator.call(organization, 2026)
    fiscal = TudlaAccounting::PeriodCreator.call(organization, 2027, 7)

    expect(helper.tc_period_label(year)).to eq("2026")
    expect(helper.tc_period_label(year.children.order(:from_date).third)).to eq("Mar 2026")
    expect(helper.tc_period_label(fiscal)).to eq("1 Jul 2027 – 30 Jun 2028")
  end
end
