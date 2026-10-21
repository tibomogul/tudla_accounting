require "rails_helper"
require_relative "../../support/configuration"

RSpec.describe "Entry numbers and references" do
  include_context "with isolated TudlaAccounting configuration"

  let(:organization) { create(:organization, currency: "USD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }
  let(:cash) { create(:tudla_accounting_account, code: "1000", category: :asset, organization: organization) }
  let(:capital) { create(:tudla_accounting_account, code: "3000", category: :equity, organization: organization) }

  def draft(on = Time.zone.local(2026, 2, 1), org: organization, debit: cash, credit: capital, reference: nil)
    entry = build(:tudla_accounting_entry, organization: org, particulars: "Capital", transacted_at: on, reference: reference)
    entry.details.build(account: debit, tally: :debit, amount_cents: 100_00, currency: "USD")
    entry.details.build(account: credit, tally: :credit, amount_cents: 100_00, currency: "USD")
    entry.tap(&:save!)
  end

  def posted(on = Time.zone.local(2026, 2, 1), **options) = draft(on, **options).tap { |entry| entry.post(entry.transacted_at) }

  it "numbers entries as they are posted, whatever their dates, leaving drafts unnumbered" do
    march = draft(Time.zone.local(2026, 3, 1))
    january = draft(Time.zone.local(2026, 1, 1))
    expect([ march.number, march.number_label ]).to eq([ nil, nil ])

    march.post(march.transacted_at)
    january.post(january.transacted_at)
    expect([ march.number, january.number ]).to eq([ 1, 2 ])
    expect(january.reload).to have_attributes(number: 2, number_series: "", number_label: "#2")
  end

  it "gives a number back when the post is rolled back, so posted entries have no gaps" do
    TudlaAccounting::Entry.transaction(requires_new: true) do
      posted
      raise ActiveRecord::Rollback
    end
    expect(posted.number).to eq(1)
  end

  it "numbers an entry created already posted" do
    entry = TudlaAccounting::Entry.create_from_ruby_hash(
      organization_type: "Organization", organization_id: organization.id, particulars: "Open invoice",
      transacted_at: "2025-12-31T00:00:00Z", posted_at: "2025-12-31T00:00:00Z",
      details: [ { account_code: cash.code, amount: "USD 10.00" }, { account_code: capital.code, amount: "USD 10.00" } ]
    )
    expect(entry.number).to eq(1)
  end

  it "counts each organization's entries on their own" do
    other = create(:organization, currency: "USD")
    TudlaAccounting::PeriodCreator.call(other, 2026)
    other_cash = create(:tudla_accounting_account, code: "1000", category: :asset, organization: other)
    other_capital = create(:tudla_accounting_account, code: "3000", category: :equity, organization: other)

    posted
    expect(posted(org: other, debit: other_cash, credit: other_capital).number).to eq(1)
    expect(posted.number).to eq(2)
  end

  it "keeps numbers fixed once posted, and only on posted entries" do
    entry = posted
    unposted = draft
    refused = ->(&change) { TudlaAccounting::Entry.transaction(requires_new: true, &change) } # a savepoint, so the example's transaction survives
    expect { refused.call { entry.update_columns(number: 9) } }.to raise_error(ActiveRecord::StatementInvalid, /cannot be changed/)
    expect { refused.call { unposted.update_columns(number: 9) } }.to raise_error(ActiveRecord::StatementInvalid, /numbered_when_posted/)
  end

  it "keeps the reference on the reversal, which takes the next number" do
    entry = posted(reference: "  CHQ 1001 ")
    expect(entry.reference).to eq("CHQ 1001")
    expect(entry.reverse!(on: Date.new(2026, 2, 5))).to have_attributes(reference: "CHQ 1001", number: 2)
    expect(draft(reference: " ").reference).to be_nil
  end

  it "takes a reference from create_from_ruby_hash" do
    entry = TudlaAccounting::Entry.create_from_ruby_hash(
      organization_type: "Organization", organization_id: organization.id, particulars: "Rent", reference: "INV-77",
      transacted_at: "2026-02-01T00:00:00Z",
      details: [ { account_code: cash.code, amount: "USD 10.00" }, { account_code: capital.code, amount: "USD 10.00" } ]
    )
    expect(entry.reference).to eq("INV-77")
    expect { TudlaAccounting::Entry.create_from_ruby_hash(organization_type: "Organization", organization_id: organization.id, particulars: "x", reference: 7, transacted_at: "2026-02-01T00:00:00Z", details: []) }
      .to raise_error(ArgumentError, "reference must be a string")
  end

  describe "series" do
    it "restarts each financial year, named by the year it ends in" do
      TudlaAccounting.configuration.entry_number_series = :financial_year
      TudlaAccounting::PeriodCreator.call(organization, 2027, 1, 1)
      expect(posted(Time.zone.local(2026, 5, 1))).to have_attributes(number: 1, number_series: "2026")
      expect(posted(Time.zone.local(2027, 5, 1))).to have_attributes(number: 1, number_series: "2027")
      expect(posted(Time.zone.local(2026, 6, 1))).to have_attributes(number: 2, number_series: "2026")
    end

    it "names a fiscal year by the year it ends in" do
      TudlaAccounting.configuration.entry_number_series = :financial_year
      TudlaAccounting::PeriodCreator.call(organization, 2027, 7, 1)
      expect(posted(Time.zone.local(2027, 8, 1)).number_series).to eq("2028")
    end

    it "takes the series from a callable, and can change with the numbers posted kept" do
      first = posted
      TudlaAccounting.configuration.entry_number_series = ->(entry) { entry.source_type == "Invoice" ? "INV" : "JE" }
      expect(posted).to have_attributes(number: 1, number_series: "JE")
      expect(first.reload).to have_attributes(number: 1, number_series: "")
    end

    it "refuses an unknown series" do
      expect { TudlaAccounting.configuration.entry_number_series = :monthly }
        .to raise_error(ArgumentError, /unknown entry number series :monthly; expected one of :organization, :financial_year or a callable/)
    end
  end

  describe "format" do
    it "shows the number with a format string, or a callable's answer" do
      TudlaAccounting.configuration.entry_number_series = :financial_year
      entry = posted
      TudlaAccounting.configuration.entry_number_format = "JE-%{series}-%<number>05d"
      expect(entry.number_label).to eq("JE-2026-00001")
      TudlaAccounting.configuration.entry_number_format = ->(numbered) { "No. #{numbered.number}" }
      expect(entry.number_label).to eq("No. 1")
    end
  end
end
