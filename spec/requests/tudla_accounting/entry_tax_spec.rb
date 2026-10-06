require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "Tax on entry lines", type: :request do
  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, currency: "AUD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    sign_in_as(organization)
    TudlaAccounting::AccountsCreator.call([
      { code: "1100", name: "Receivables", category: "asset" }, { code: "2200", name: "GST", category: "liability" },
      { code: "4000", name: "Sales", category: "income" }, { code: "4100", name: "Exports", category: "income" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def lines(entry) = entry.reload.details.map { |d| [ d.account.code, d.tally, d.amount_cents, d.tax_code&.code, d.tax_role ] }

  def save(lines, inclusive: false, entry: nil)
    attributes = { particulars: "Invoice 1", transacted_at: "2026-03-02", tax_inclusive: (inclusive ? "1" : "0"),
                   lines: lines.each_with_index.to_h { |line, index| [ index.to_s, line ] } }
    entry ? patch(routes.entry_path(entry), params: { entry: attributes }) : post(routes.entries_path, params: { entry: attributes })
    entry || TudlaAccounting::Entry.order(:id).last
  end

  it "leaves the tax column out until the organization has tax codes" do
    get routes.new_entry_path
    expect(css_select("select[aria-label=Tax]")).to be_empty
    expect(response.body).not_to include("include the tax")
  end

  context "with tax codes" do
    let!(:gst) { TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST on sales", rate: "0.1", kind: :sales, account: account("2200")) }
    let!(:free) { TudlaAccounting::TaxCode.create!(organization: organization, code: "FRE", name: "GST-free", rate: 0, kind: :sales) }

    it "offers the active codes, with their rates" do
      TudlaAccounting::TaxCode.create!(organization: organization, code: "OLD", name: "Old", rate: "0.05", kind: :sales, account: account("2200"), active: false)
      get routes.new_entry_path
      expect(css_select("template").first.inner_html).to include("No tax")
      expect(Nokogiri::HTML(css_select("template").first.inner_html).css("select[aria-label=Tax] option").map { |o| [ o.text, o["data-rate"] ] })
        .to eq([ [ "No tax", nil ], [ "FRE (0%)", "0.0" ], [ "GST (10%)", "0.1" ] ])
    end

    it "adds the tax on taxed lines when saving, one tax line per code and side" do
      entry = save([ { account_id: account("1100").id, debit: "330" },
                     { account_id: account("4000").id, credit: "200", tax_code_id: gst.id },
                     { account_id: account("4000").id, credit: "100", tax_code_id: gst.id } ])

      expect(response).to redirect_to(routes.entry_path(entry))
      expect(lines(entry)).to contain_exactly([ "1100", "debit", 330_00, nil, nil ], [ "4000", "credit", 200_00, "GST", "base" ],
                                              [ "4000", "credit", 100_00, "GST", "base" ], [ "2200", "credit", 30_00, "GST", "tax" ])
      get routes.entry_path(entry)
      expect(css_select("[data-tax=base]").map { |tag| tag.text.squish }).to eq([ "taxed GST (10%)", "taxed GST (10%)" ])
      expect(css_select("[data-tax=tax]").map { |tag| tag.text.squish }).to eq([ "GST tax" ])
    end

    it "splits the tax out of amounts that include it" do
      entry = save([ { account_id: account("1100").id, debit: "110" }, { account_id: account("4000").id, credit: "110", tax_code_id: gst.id } ], inclusive: true)
      expect(lines(entry)).to contain_exactly([ "1100", "debit", 110_00, nil, nil ], [ "4000", "credit", 100_00, "GST", "base" ], [ "2200", "credit", 10_00, "GST", "tax" ])
    end

    it "shows the saved lines without their tax line when editing, and works the tax out again on save" do
      entry = save([ { account_id: account("1100").id, debit: "110" }, { account_id: account("4000").id, credit: "100", tax_code_id: gst.id } ])
      base, = entry.details.select(&:tax_base?)
      debit_line = entry.details.find(&:debit?)

      get routes.edit_entry_path(entry)
      expect(css_select("tbody[data-entry-lines-target=lines] tr").size).to eq(2)
      expect(css_select("select[aria-label=Tax] option[selected]").map(&:text)).to eq([ "GST (10%)" ])

      save([ { id: debit_line.id, account_id: account("1100").id, debit: "100" },
             { id: base.id, account_id: account("4100").id, credit: "100", tax_code_id: free.id } ], entry: entry)
      expect(lines(entry)).to contain_exactly([ "1100", "debit", 100_00, nil, nil ], [ "4100", "credit", 100_00, "FRE", "base" ])

      save([ { id: debit_line.id, account_id: account("1100").id, debit: "100" },
             { id: base.id, account_id: account("4100").id, credit: "100", tax_code_id: "" } ], entry: entry)
      expect(lines(entry)).to contain_exactly([ "1100", "debit", 100_00, nil, nil ], [ "4100", "credit", 100_00, nil, nil ])
    end

    it "keeps the tax in the balance check, and leaves removed lines untaxed" do
      save([ { account_id: account("1100").id, debit: "100" }, { account_id: account("4000").id, credit: "100", tax_code_id: gst.id },
             { account_id: account("4000").id, credit: "50", tax_code_id: gst.id, _destroy: "1" } ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("The credit and debit amounts are not equal") # 100 against 100 + 10 tax
      expect(css_select("tbody[data-entry-lines-target=lines] tr").size).to eq(2) # the generated tax line isn't a line to edit
    end

    it "refuses another organization's tax code" do
      other = TudlaAccounting::TaxCode.create!(organization: create(:organization), code: "VAT", name: "VAT", rate: 0, kind: :sales)
      save([ { account_id: account("1100").id, debit: "100" }, { account_id: account("4000").id, credit: "100", tax_code_id: other.id } ])
      expect(response).to have_http_status(:not_found)
    end
  end
end
