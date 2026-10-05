require "rails_helper"
require_relative "../../support/sign_in"
require_relative "../../support/entry_sources"

RSpec.describe "Entries", type: :request do
  let(:routes) { TudlaAccounting::Engine.routes.url_helpers }
  let(:organization) { create(:organization, name: "Acme", currency: "AUD") }
  let(:this_year) { Date.current.year }

  before do
    sign_in_as(organization)
    TudlaAccounting::PeriodCreator.call(organization, this_year)
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Assets", category: "asset", children: [ { code: "1010", name: "Cash", category: "asset" } ] },
      { code: "3000", name: "Capital", category: "equity" },
      { code: "4000", name: "Sales", category: "income" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by(organization: organization, code: code)
  def aud(amount) = Money.from_amount(BigDecimal(amount.to_s), "AUD")
  def rows = css_select("tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
  def on(month, day = 10) = Time.zone.local(this_year, month, day)

  def entry(particulars: "Capital contribution", at: on(2), amount: 500, debit: "1010", credit: "3000", posted: false)
    record = build(:tudla_accounting_entry, organization: organization, particulars: particulars, transacted_at: at)
    record.details.build(account: account(debit), tally: :debit, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
    record.details.build(account: account(credit), tally: :credit, amount_cents: aud(amount).cents, currency: "AUD", organization: organization)
    record.save!
    record.post(at) if posted
    record
  end

  def lines(*rows)
    rows.each_with_index.to_h { |(code, debit, credit), index| [ index.to_s, { account_id: code && account(code).id, debit: debit, credit: credit } ] }
  end

  describe "GET /entries" do
    before do
      entry(particulars: "Capital contribution", at: on(2), posted: true)
      entry(particulars: "Cash sale", at: on(3), amount: 120, credit: "4000")
      entry(particulars: "Another sale", at: on(4), amount: 80, credit: "4000", posted: true)
    end

    it "lists entries newest first with their status and amount" do
      get routes.entries_path
      expect(rows).to eq([
        [ on(4).strftime("%-d %b %Y"), "Another sale", "Posted #{on(4).strftime('%-d %b %Y')}", "80.00" ],
        [ on(3).strftime("%-d %b %Y"), "Cash sale", "Draft", "120.00" ],
        [ on(2).strftime("%-d %b %Y"), "Capital contribution", "Posted #{on(2).strftime('%-d %b %Y')}", "500.00" ]
      ])
    end

    it "filters by text, status, dates and account (including sub-accounts)" do
      get routes.entries_path(q: "SALE")
      expect(rows.map(&:second)).to eq([ "Another sale", "Cash sale" ])

      get routes.entries_path(status: "draft")
      expect(rows.map(&:second)).to eq([ "Cash sale" ])

      get routes.entries_path(status: "posted", from: on(3, 1).to_date, thru: on(4, 30).to_date)
      expect(rows.map(&:second)).to eq([ "Another sale" ])

      get routes.entries_path(account_id: account("3000").id)
      expect(rows.map(&:second)).to eq([ "Capital contribution" ])

      get routes.entries_path(account_id: account("1000").id)
      expect(rows.size).to eq(3)
    end

    it "says when nothing matches, and leaves other organizations' entries out" do
      other = create(:organization)
      create(:tudla_accounting_entry, organization: other, particulars: "Not ours")

      get routes.entries_path(q: "Not ours")
      expect(rows).to eq([ [ "No entries match." ] ])
    end

    it "refuses another organization's account as a filter" do
      get routes.entries_path(account_id: create(:tudla_accounting_account, organization: create(:organization)).id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "creating a draft" do
    it "starts with today's date and two blank lines" do
      get routes.new_entry_path
      expect(css_select("#entry_transacted_at").first["value"]).to eq(Date.current.iso8601)
      expect(css_select("tbody tr[data-entry-lines-target=line]").size).to eq(2)
      expect(css_select("template tr")).to be_present
    end

    it "saves debit and credit columns as a draft, ignoring blank lines" do
      post routes.entries_path, params: { entry: { particulars: "Owner's capital", transacted_at: on(2).to_date.iso8601,
                                                   lines: lines([ "1010", "1,500.50", "" ], [ "3000", "", "1500.5" ], [ nil, "", "" ]) } }

      created = TudlaAccounting::Entry.last
      expect(response).to redirect_to(routes.entry_path(created))
      expect(created).to have_attributes(particulars: "Owner's capital", posted_at: nil, transacted_at: on(2).beginning_of_day, organization: organization)
      expect(created.details.map { |line| [ line.account.code, line.tally, line.amount ] }).to contain_exactly([ "1010", "debit", aud("1500.50") ], [ "3000", "credit", aud("1500.50") ])
      expect(TudlaAccounting::Balance.count).to eq(0)
      follow_redirect!
      expect(response.body).to include("Draft entry saved. Post it to update the balances.")
    end

    it "shows what is wrong, keeping what was typed" do
      post routes.entries_path, params: { entry: { particulars: "", transacted_at: on(2).to_date.iso8601,
                                                   lines: lines([ "1010", "100", "" ], [ "3000", "", "90" ], [ "4000", "5", "5" ], [ nil, "abc", "" ]) } }

      expect(response).to have_http_status(:unprocessable_entity)
      messages = css_select(".tc-alert-danger li").map(&:text)
      expect(messages).to include("Particulars can't be blank", "The credit and debit amounts are not equal",
                                  "Line 3 has both a debit and a credit; use one line for each", "Line 4: abc isn't an amount")
      expect(css_select("input[name='entry[lines][0][debit]']").first["value"]).to eq("100.00")
      expect(TudlaAccounting::Entry.count).to eq(0)
    end

    it "needs an account and an amount on every line" do
      post routes.entries_path, params: { entry: { particulars: "X", transacted_at: on(2).to_date.iso8601, lines: lines([ nil, "100", "" ], [ "3000", "", "" ]) } }
      expect(css_select(".tc-alert-danger li").map(&:text)).to include("Details account must exist", "Details amount cents must be more than zero")
    end

    it "refuses another organization's account on a line" do
      stranger = create(:tudla_accounting_account, organization: create(:organization))
      post routes.entries_path, params: { entry: { particulars: "X", transacted_at: on(2).to_date.iso8601,
                                                   lines: { "0" => { account_id: stranger.id, debit: "1" } } } }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "a draft" do
    let!(:draft) { entry }

    it "shows its lines and draft actions" do
      get routes.entry_path(draft)

      expect(response.body).to include("Capital contribution", "Draft")
      expect(rows).to eq([ [ "1010 - Cash", "500.00", "" ], [ "3000 - Capital", "", "500.00" ], [ "Total", "500.00", "500.00" ] ])
      expect(css_select("form button").map(&:text)).to include("Post", "Delete")
      expect(response.body).not_to include("Reverse on")
    end

    it "can be edited: lines changed, added and removed" do
      get routes.edit_entry_path(draft)
      expect(css_select("tbody[data-entry-lines-target=lines] input[name$='[debit]']").map { |input| input["value"] }).to eq([ "500.00", "" ])

      cash, capital = draft.details.sort_by { |line| line.debit? ? 0 : 1 }
      patch routes.entry_path(draft), params: { entry: { particulars: "Capital, corrected", transacted_at: on(2).to_date.iso8601, lines: {
        "0" => { id: cash.id, account_id: account("1010").id, debit: "600", credit: "" },
        "1" => { id: capital.id, account_id: account("3000").id, debit: "", credit: "500", _destroy: "1" },
        "2" => { account_id: account("3000").id, debit: "", credit: "600" }
      } } }

      expect(response).to redirect_to(routes.entry_path(draft))
      expect(draft.reload.particulars).to eq("Capital, corrected")
      expect(draft.details.map { |line| [ line.account.code, line.tally, line.amount_cents ] }).to contain_exactly([ "1010", "debit", 600_00 ], [ "3000", "credit", 600_00 ])
    end

    it "keeps a removed line removed when the edit fails" do
      cash, capital = draft.details.sort_by { |line| line.debit? ? 0 : 1 }
      patch routes.entry_path(draft), params: { entry: { particulars: "", transacted_at: on(2).to_date.iso8601, lines: {
        "0" => { id: cash.id, account_id: account("1010").id, debit: "500" },
        "1" => { id: capital.id, account_id: account("3000").id, credit: "500", _destroy: "1" },
        "2" => { account_id: account("3000").id, credit: "500" }
      } } }

      expect(response).to have_http_status(:unprocessable_entity)
      removed = css_select("tr[hidden]")
      expect(removed.size).to eq(1)
      expect(removed.first.at_css("input[name$='[_destroy]']")["value"]).to eq("1")
    end

    it "can be deleted" do
      expect { delete routes.entry_path(draft) }.to change(TudlaAccounting::Entry, :count).by(-1)
      expect(response).to redirect_to(routes.entries_path)
    end

    it "posts into the period of its date" do
      post routes.post_entry_path(draft)

      expect(response).to redirect_to(routes.entry_path(draft))
      expect(flash[:notice]).to eq("Entry posted.")
      expect(draft.reload.posted_at).to eq(on(2))
      expect(TudlaAccounting::Balance.get(account("1010"), TudlaAccounting::Period.roots.first).ending_amount).to eq(aud(500))
    end

    it "explains why it can't be posted" do
      outside = entry(at: Time.zone.local(this_year + 3, 1, 1))
      post routes.post_entry_path(outside)
      expect(flash[:alert]).to eq("The entry could not be posted: no financial year covers its date.")
      expect(outside.reload).to be_draft
    end
  end

  describe "a posted entry" do
    let!(:posted) { entry(posted: true) }

    it "offers reversing instead of editing" do
      get routes.entry_path(posted)
      expect(response.body).to include("Posted", "Reverse on")
      expect(css_select("form button").map(&:text)).not_to include("Post", "Delete")
    end

    it "can't be edited or deleted" do
      get routes.edit_entry_path(posted)
      expect(response).to redirect_to(routes.entry_path(posted))
      expect(flash[:alert]).to eq("A posted entry can't be changed; reverse it instead.")

      expect { delete routes.entry_path(posted) }.not_to change(TudlaAccounting::Entry, :count)

      post routes.post_entry_path(posted)
      expect(flash[:alert]).to eq("The entry could not be posted: entry is already posted.")
    end

    it "is reversed on a chosen date, linking both ways" do
      post routes.reverse_entry_path(posted), params: { on: on(5, 1).to_date.iso8601 }

      reversal = TudlaAccounting::Entry.find_by(related: posted)
      expect(response).to redirect_to(routes.entry_path(reversal))
      expect(flash[:notice]).to eq("Entry reversed on #{on(5, 1).strftime('%-d %b %Y')}.")
      expect(reversal).to have_attributes(particulars: "Reversal of: Capital contribution", posted_at: on(5, 1).beginning_of_day)
      expect(TudlaAccounting::Balance.get(account("1010"), TudlaAccounting::Period.roots.first).ending_amount).to eq(aud(0))

      get routes.entry_path(reversal)
      expect(response.body).to include("Related to", "Capital contribution")
      get routes.entry_path(posted)
      expect(response.body).to include("Reversed by", "Reversal of: Capital contribution")
      expect(response.body).not_to include("Reverse on")
    end

    it "reverses today when no date is given, and only once" do
      post routes.reverse_entry_path(posted)
      expect(TudlaAccounting::Entry.find_by(related: posted).transacted_at.to_date).to eq(Date.current)

      post routes.reverse_entry_path(posted)
      expect(flash[:alert]).to eq("The entry could not be reversed: this entry has already been reversed.")
    end
  end

  context "with receivables" do
    include_context "with entry source models"

    it "explains that an invoice can't be reversed here" do
      TudlaAccounting.configuration.receivable_account_code = "1010"
      invoice = build(:tudla_accounting_entry, organization: organization, particulars: "Invoice", transacted_at: on(3), source: Invoice.create!)
      invoice.details.build(account: account("1010"), tally: :debit, amount_cents: 100, currency: "AUD", organization: organization)
      invoice.details.build(account: account("4000"), tally: :credit, amount_cents: 100, currency: "AUD", organization: organization)
      invoice.save!
      invoice.post(invoice.transacted_at)

      get routes.entry_path(invoice)
      expect(response.body).to include("From Invoice", "Entries that open or settle receivables or payables can&#39;t be reversed here.")
      expect(response.body).not_to include("Reverse on")
    end
  end

  it "does not show another organization's entry" do
    get routes.entry_path(create(:tudla_accounting_entry, organization: create(:organization)))
    expect(response).to have_http_status(:not_found)
  end
end
