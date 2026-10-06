require "rails_helper"
require_relative "../../support/sign_in"

RSpec.describe "Activity", type: :request do
  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "USD") }

  before { sign_in_as(organization) }

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def rows = css_select("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }

  it "says when nothing has happened yet, and is in the navigation" do
    get routes.activity_path
    expect(response.body).to include("Nothing recorded yet.")
    expect(css_select("nav a.tc-nav-link[aria-current=page]").text).to eq("Activity")
  end

  context "with books under way" do
    let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
    let!(:entry) do
      TudlaAccounting::AccountsCreator.call([ { code: "1000", name: "Cash", category: "asset" }, { code: "3100", name: "Capital", category: "equity" } ], organization)
      record = build(:tudla_accounting_entry, organization: organization, particulars: "Capital in", transacted_at: Time.zone.local(2026, 3, 1))
      record.details.build(account: account("1000"), tally: :debit, amount_cents: 100_00, currency: "USD", organization: organization)
      record.details.build(account: account("3100"), tally: :credit, amount_cents: 100_00, currency: "USD", organization: organization)
      record.save!
      record
    end

    before do
      post routes.post_entry_path(entry) # through the page, so the dummy app's actor is recorded
      entry.reload.reverse!(on: Date.new(2026, 3, 5))
      account("1000").update!(name: "Cash at bank")
      year.children.order(:from_date).first.close!
      year.children.order(:from_date).first.reopen!(reason: "Late receipt")
      TudlaAccounting::StartingBalanceCreator.call(organization, Date.new(2026, 1, 1), [ { account_id: account("1000").id, amount_cents: 0 } ], "USD", true)
      TudlaAccounting::BalanceRebuilder.new(organization).rebuild!
      TudlaAccounting::PeriodCreator.call(organization, 2030).destroy_with_subtree!
      account("3100").tap { |capital| capital.update_columns(code: "3200") } # still exists
    end

    it "lists who did what, newest first, linking to what still exists" do
      get routes.activity_path

      descriptions = rows.map(&:last)
      expect(descriptions).to eq([
        "Deleted the financial year 2030", "Created the financial year 2030", "Rebuilt the balances: 0 balances corrected",
        "Saved the opening balances at 1 Jan 2026", "Reopened Jan 2026: “Late receipt”", "Closed Jan 2026",
        "Changed 1000 - Cash at bank: name", "Reversed Capital in on 5 Mar 2026", "Posted Reversal of: Capital in",
        "Posted Capital in", "Added the account 3100 - Capital", "Added the account 1000 - Cash", "Created the financial year 2026"
      ])
      expect(rows.find { |row| row.last == "Posted Capital in" }[1]).to eq("Demo user")
      expect(rows.first[1]).to eq("System")
      expect(css_select("a[href='#{routes.entry_path(entry)}']").map(&:text)).to include("Capital in")
      expect(css_select("a[href='#{routes.period_path(year)}']").map(&:text)).to include("Jan 2026", "2026")
      expect(css_select("a[href='#{routes.account_path(account('1000'))}']").map(&:text)).to include("1000 - Cash at bank")
      expect(css_select("a").map(&:text)).not_to include("2030")
    end

    it "shows one kind of activity, and only this organization's" do
      other = create(:organization)
      TudlaAccounting::PeriodCreator.call(other, 2026)

      get routes.activity_path(kind: "period")
      expect(rows.map(&:last)).to all(match(/financial year|Jan 2026/))
      expect(rows.size).to eq(5)
      expect(css_select("#kind option[selected]").text).to eq("Periods")

      get routes.activity_path(kind: "nonsense")
      expect(rows.size).to eq(13)
    end

    it "shows a deleted account without a link" do
      create(:tudla_accounting_account, organization: organization, code: "9999", name: "Spare").destroy!
      get routes.activity_path
      expect(rows.first.last).to eq("Deleted the account 9999 - Spare")
      expect(css_select("tbody tr").first.css("a")).to be_empty
    end

    it "shows a deleted draft without a link" do
      draft = build(:tudla_accounting_entry, organization: organization, particulars: "Typo", transacted_at: Time.zone.local(2026, 3, 1))
      draft.details.build(account: account("1000"), tally: :debit, amount_cents: 1, currency: "USD", organization: organization)
      draft.details.build(account: account("3200"), tally: :credit, amount_cents: 1, currency: "USD", organization: organization)
      draft.save!
      delete routes.entry_path(draft)

      get routes.activity_path
      expect(rows.first.last).to eq("Deleted the draft Typo")
      expect(css_select("tbody tr").first.css("a")).to be_empty
    end
  end
end
