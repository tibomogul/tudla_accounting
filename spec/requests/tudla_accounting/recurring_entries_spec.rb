require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/configuration"

RSpec.describe "Recurring entries", type: :request do
  include_context "with isolated TudlaAccounting configuration"
  include ActiveSupport::Testing::TimeHelpers

  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:permissions) { %i[read record post administer] }

  before do
    travel_to Time.zone.local(2026, 3, 15, 9)
    TudlaAccounting.configuration.authorize = ->(_controller, permission) { permissions.include?(permission) }
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, 2026)
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash", category: "asset" }, { code: "2200", name: "GST", category: "liability" },
      { code: "6100", name: "Rent", category: "expense" }
    ], organization)
    @gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :purchases, account: account("2200"))
    @ops = TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department").dimension_values.create!(code: "OPS", name: "Ops")
  end

  after { travel_back }

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)
  def rows = css_select("tbody tr[data-recurring-entry]").map { |row| row.css("td").map { |cell| cell.text.squish } }

  def form(**overrides)
    { name: "Rent", particulars: "Office rent", reference: "Lease 7", frequency: "monthly", interval: "1", day_of_month: "1",
      starts_on: "2026-01-01", ends_on: "", occurrences_limit: "", post_automatically: "0", reverse_next_month: "0", tax_inclusive: "1",
      lines: { "0" => { account_id: account("6100").id, debit: "1,100", credit: "", description: "Level 3", tax_code_id: @gst.id, dimensions: { @ops.dimension_id.to_s => @ops.id } },
               "1" => { account_id: account("1010").id, debit: "", credit: "1100" },
               "2" => { account_id: "", debit: "", credit: "", description: "" } } }.merge(overrides)
  end

  def rent = TudlaAccounting::RecurringEntry.find_by!(organization: organization, name: "Rent")

  it "creates one from the form, showing when it is next due" do
    get routes.new_recurring_entry_path
    expect(css_select("select[name='recurring_entry[lines][0][account_id]']")).not_to be_empty

    post routes.recurring_entries_path, params: { recurring_entry: form }
    expect(response).to redirect_to(routes.recurring_entry_path(rent))
    expect(flash[:notice]).to eq("Recurring entry saved. The next entry is due on 1 Jan 2026.")
    expect(rent).to have_attributes(reference: "Lease 7", tax_inclusive: true, day_of_month: 1)
    expect(rent.lines.map { |line| [ line.account.code, line.tally, line.amount_cents, line.description, line.tax_code, line.dimension_value_ids ] })
      .to eq([ [ "6100", "debit", 1_100_00, "Level 3", @gst, [ @ops.id ] ], [ "1010", "credit", 1_100_00, nil, nil, [] ] ])

    get routes.recurring_entries_path
    expect(rows).to eq([ [ "Rent", "Every month on the 1st", "1 Jan 2026 Due", "Drafts", "1,100.00" ] ])
  end

  it "shows what is wrong, keeping what was typed" do
    post routes.recurring_entries_path, params: { recurring_entry: form(day_of_month: "last", lines: { "0" => { account_id: account("6100").id, debit: "10", credit: "5" },
                                                                                                     "1" => { account_id: account("1010").id, debit: "", credit: "lots" } }) }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Line 1 has both a debit and a credit", "Line 2: lots isn&#39;t an amount")
    expect(css_select("select[name='recurring_entry[day_of_month]'] option[selected]").map(&:text)).to eq([ "Last day" ])
  end

  it "makes the entries due, and a one-off draft for today" do
    post routes.recurring_entries_path, params: { recurring_entry: form }
    get routes.recurring_entries_path
    post routes.run_recurring_entries_path
    expect(flash[:notice]).to eq("Made 3 entries, 0 of them posted.")
    expect(rent.entries.map { |entry| [ entry.transacted_at.to_date, entry.details.sum(:amount_cents) ] })
      .to contain_exactly([ Date.new(2026, 1, 1), 2_200_00 ], [ Date.new(2026, 2, 1), 2_200_00 ], [ Date.new(2026, 3, 1), 2_200_00 ]) # 1,000 + 100 tax, and 1,100
    post routes.run_recurring_entries_path
    expect(flash[:notice]).to eq("No entries were due.")
    get routes.activity_path(kind: "recurring_entry")
    expect(css_select("a[href='#{routes.recurring_entry_path(rent)}']").map(&:text)).to include("Rent")
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish }).to include("Made the entry for 1 Mar 2026 from Rent")

    post routes.make_recurring_entry_path(rent)
    draft = TudlaAccounting::Entry.where(source: rent).order(:id).last
    expect(response).to redirect_to(routes.entry_path(draft))
    expect(draft).to have_attributes(transacted_at: Time.zone.local(2026, 3, 15), idempotency_key: nil)
    expect(rent.reload.occurrences_count).to eq(3) # apart from the schedule

    get routes.entry_path(draft)
    expect(css_select("a[href='#{routes.recurring_entry_path(rent)}']").map(&:text)).to eq([ "Rent" ])
    get routes.recurring_entry_path(rent)
    expect(css_select("tr[data-made-entry]").size).to eq(4)
  end

  it "says why an entry couldn't be made, on its page and the dashboard" do
    post routes.recurring_entries_path, params: { recurring_entry: form }
    TudlaAccounting::Account.where(id: account("6100").id).update_all(active: false)
    post routes.run_recurring_entries_path
    expect(flash[:alert]).to eq("Some couldn't be made or posted: Rent: 1 Jan 2026: account 6100 is inactive.")

    get routes.root_path
    expect(css_select("[data-recurring-due]").first.text.squish).to include("1 recurring entry is due.", "1 recurring entry had a problem last time.")
    post routes.make_recurring_entry_path(rent)
    expect(flash[:alert]).to eq("No draft was made: account 6100 is inactive.")
  end

  it "copies an entry's lines, its tax lines aside" do
    entry = TudlaAccounting::Entry.create_from_ruby_hash(
      organization_type: "Organization", organization_id: organization.id, particulars: "Internet", reference: "INV-9", transacted_at: "2026-03-10T00:00:00Z",
      details: [ { account_code: "6100", amount: "AUD 100.00", tax_code: "GST", dimensions: { "DEPT" => "OPS" } }, { account_code: "1010", amount: "AUD -110.00" } ]
    )
    get routes.entry_path(entry)
    expect(css_select("a").map { |link| link["href"] }).to include(routes.new_recurring_entry_path(entry_id: entry.id))

    get routes.new_recurring_entry_path(entry_id: entry.id)
    expect(css_select("input[name='recurring_entry[particulars]']").first["value"]).to eq("Internet")
    lines = css_select("tbody[data-entry-lines-target=lines] tr")
    expect(lines.size).to eq(2)
    expect(lines.first.css("select[name$='[tax_code_id]'] option[selected]").map(&:text)).to eq([ "GST (10%)" ])
    expect(lines.first.css("select[name$='[#{@ops.dimension_id}]'] option[selected]").map(&:text)).to eq([ "Ops" ])
  end

  it "edits, deactivates and deletes one, on the activity log" do
    post routes.recurring_entries_path, params: { recurring_entry: form }
    template = rent
    debit, credit = template.lines
    patch routes.recurring_entry_path(template), params: { recurring_entry: form(lines: {
      "0" => { id: debit.id, account_id: account("6100").id, debit: "1100", credit: "" }, "1" => { id: credit.id, account_id: account("1010").id, debit: "", credit: "1" }
    }) }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("The credit and debit amounts are not equal")
    patch routes.recurring_entry_path(template), params: { recurring_entry: form(day_of_month: "last", active: "0", lines: {
      "0" => { id: debit.id, account_id: account("6100").id, debit: "1100", credit: "", description: "", tax_code_id: "", dimensions: { @ops.dimension_id.to_s => "" } },
      "1" => { id: credit.id, account_id: account("1010").id, debit: "", credit: "1100", description: "", tax_code_id: "" }
    }) }
    expect(template.reload).to have_attributes(day_of_month: nil, active: false, next_on: Date.new(2026, 1, 31))
    expect(template.lines.first).to have_attributes(description: nil, tax_code: nil, dimension_value_ids: [])

    delete routes.recurring_entry_path(template)
    expect(flash[:notice]).to eq("Recurring entry Rent deleted. The entries made from it stay.")
    get routes.activity_path(kind: "recurring_entry")
    expect(css_select("tbody tr").map { |row| row.css("td").last.text.squish })
      .to eq([ "Deleted the recurring entry Rent", "Changed the recurring entry Rent: active, day of month", "Added the recurring entry Rent" ])
  end

  context "when allowed only to read" do
    let(:permissions) { %i[read] }

    it "shows them, but neither changes nor runs them" do
      get routes.recurring_entries_path
      expect(response.body).not_to include("New recurring entry")
      post routes.recurring_entries_path, params: { recurring_entry: form }
      expect(response).to have_http_status(:forbidden)
      post routes.run_recurring_entries_path
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "keeps other organizations' to themselves" do
    other = create(:organization, currency: "AUD")
    TudlaAccounting::AccountsCreator.call([ { code: "1010", name: "Cash", category: "asset" }, { code: "6100", name: "Rent", category: "expense" } ], other)
    theirs = TudlaAccounting::RecurringEntry.new(organization: other, name: "Theirs", particulars: "x", frequency: "monthly", starts_on: Date.new(2026, 1, 1))
    theirs.lines.build(account: TudlaAccounting::Account.find_by!(organization: other, code: "6100"), tally: :debit, amount_cents: 100)
    theirs.lines.build(account: TudlaAccounting::Account.find_by!(organization: other, code: "1010"), tally: :credit, amount_cents: 100)
    theirs.save!
    get routes.recurring_entry_path(theirs)
    expect(response).to have_http_status(:not_found)
  end
end
