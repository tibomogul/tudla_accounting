require "rails_helper"

RSpec.describe TudlaAccounting::RecurringEntry do
  let(:organization) { create(:organization, currency: "USD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash", category: "asset" }, { code: "1500", name: "Equipment", category: "asset" },
      { code: "1590", name: "Accumulated depreciation", category: "asset", contra_account: "1500" },
      { code: "2200", name: "GST", category: "liability" }, { code: "2300", name: "Accrued expenses", category: "liability" },
      { code: "6100", name: "Rent", category: "expense" }, { code: "6400", name: "Depreciation", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def template(lines: [ [ "6100", :debit, 1_000_00 ], [ "1010", :credit, 1_000_00 ] ], **attrs)
    described_class.new(organization: organization, name: "Rent", particulars: "Office rent", frequency: "monthly", starts_on: Date.new(2026, 1, 1),
                        day_of_month: 1, **attrs).tap do |record|
      lines.each { |code, tally, cents, extra| record.lines.build(account: account(code), tally: tally, amount_cents: cents, **(extra || {})) }
    end
  end

  describe "the schedule" do
    it "runs monthly on a day, cut to short months, or on the last day" do
      on_31st = template(day_of_month: 31, starts_on: Date.new(2026, 1, 15))
      expect(on_31st.first_on_or_after(Date.new(2026, 1, 15))).to eq(Date.new(2026, 1, 31))
      expect(on_31st.first_on_or_after(Date.new(2026, 2, 1))).to eq(Date.new(2026, 2, 28))
      expect(template(day_of_month: nil, starts_on: Date.new(2026, 4, 30)).first_on_or_after(Date.new(2026, 5, 1))).to eq(Date.new(2026, 5, 31))
      expect(template(day_of_month: 1, starts_on: Date.new(2026, 1, 15)).first_on_or_after(Date.new(2026, 1, 15))).to eq(Date.new(2026, 2, 1))
    end

    it "runs every few weeks, months or years" do
      expect(template(frequency: "weekly", interval: 2, starts_on: Date.new(2026, 1, 5)).first_on_or_after(Date.new(2026, 1, 6))).to eq(Date.new(2026, 1, 19))
      expect(template(interval: 3).first_on_or_after(Date.new(2026, 1, 2))).to eq(Date.new(2026, 4, 1))
      expect(template(frequency: "yearly", day_of_month: 30, starts_on: Date.new(2026, 6, 1)).first_on_or_after(Date.new(2026, 7, 1))).to eq(Date.new(2027, 6, 30))
    end

    it "describes itself" do
      expect(template.schedule_label).to eq("Every month on the 1st")
      expect(template(day_of_month: nil, interval: 3).schedule_label).to eq("Every 3 months on the last day")
      expect(template(frequency: "weekly", starts_on: Date.new(2026, 1, 5)).schedule_label).to eq("Every week on Mondays")
      expect(template(frequency: "yearly", starts_on: Date.new(2026, 6, 1)).schedule_label).to eq("Every year on the 1st of June")
    end

    it "starts next_on at the first date, and stops after the end or the number given" do
      expect(template.tap(&:save!).next_on).to eq(Date.new(2026, 1, 1))

      limited = template(occurrences_limit: 2).tap(&:save!)
      limited.advance!(Date.new(2026, 1, 1))
      expect(limited.next_on).to eq(Date.new(2026, 2, 1))
      limited.advance!(Date.new(2026, 2, 1))
      expect(limited).to be_finished

      ending = template(ends_on: Date.new(2026, 1, 31)).tap(&:save!)
      ending.advance!(Date.new(2026, 1, 1))
      expect(ending.next_on).to be_nil
    end
  end

  describe "validation" do
    it "needs lines that make an entry: balanced, with accounts that can take it" do
      expect(template(lines: [ [ "6100", :debit, 100 ] ])).not_to be_valid
      unbalanced = template(lines: [ [ "6100", :debit, 100 ], [ "1010", :credit, 99 ] ])
      expect(unbalanced).not_to be_valid
      expect(unbalanced.errors[:base]).to include("The credit and debit amounts are not equal")

      account("6100").deactivate!
      inactive = template
      expect(inactive).not_to be_valid
      expect(inactive.errors[:base]).to include("Account 6100 is inactive")
      expect(template(ends_on: Date.new(2025, 12, 31), lines: [])).to have_attributes(valid?: false)
    end

    it "checks each line's tax and dimensions belong to the organization, one value per dimension" do
      department = TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department")
      ops, sales = %w[OPS SALES].map { |code| department.dimension_values.create!(code: code, name: code.capitalize) }
      both = template(lines: [ [ "6100", :debit, 100, { dimension_value_ids: [ ops.id, sales.id ] } ], [ "1010", :credit, 100 ] ])
      expect(both).not_to be_valid
      expect(both.lines.first.errors[:dimension_value_ids]).to eq([ "can have one value of each dimension" ])
    end
  end

  it "keeps an account it uses from being made inactive or deleted" do
    template.save!
    expect(account("6100").deactivation_blocker).to eq("6100 - Rent is used by the recurring entry Rent; change it or make it inactive first")
    expect(account("6100")).not_to be_deletable
  end

  it "makes each entry's hash from its lines, with tax, dimensions, descriptions and the accrual's reversal" do
    gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :purchases, account: account("2200"))
    department = TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department")
    ops = department.dimension_values.create!(code: "OPS", name: "Ops")
    record = template(lines: [ [ "6100", :debit, 1_000_00, { tax_code: gst, dimension_value_ids: [ ops.id ], description: "Level 3" } ], [ "1010", :credit, 1_100_00 ] ],
                      reverse_next_month: true).tap(&:save!)

    expect(record.entry_hash(on: Date.new(2026, 3, 1))).to include(
      transacted_at: "2026-03-01T00:00:00Z", reverse_on: "2026-04-01", source_type: "TudlaAccounting::RecurringEntry", source_id: record.id,
      idempotency_key: "recurring:#{record.id}:2026-03-01",
      details: [ { account_code: "6100", amount: "USD 1000.00", description: "Level 3", tax_code: "GST", dimensions: { "DEPT" => "OPS" } },
                 { account_code: "1010", amount: "USD -1100.00" } ]
    )
  end

  it "is on the audit trail" do
    record = template.tap(&:save!)
    record.update!(particulars: "Office rent, level 3")
    record.destroy!
    expect(TudlaAccounting::AuditEvent.where(organization: organization).where("action LIKE 'recurring_entry%'").pluck(:action, :subject_label))
      .to eq([ %w[recurring_entry.created Rent], %w[recurring_entry.updated Rent], %w[recurring_entry.deleted Rent] ])
  end
end

RSpec.describe TudlaAccounting::RecurringEntryRunner do
  let(:organization) { create(:organization, currency: "USD") }
  let!(:year) { TudlaAccounting::PeriodCreator.call(organization, 2026) }

  before do
    TudlaAccounting::AccountsCreator.call([
      { code: "1010", name: "Cash", category: "asset" }, { code: "2300", name: "Accrued expenses", category: "liability" },
      { code: "6100", name: "Rent", category: "expense" }
    ], organization)
  end

  def account(code) = TudlaAccounting::Account.find_by!(organization: organization, code: code)

  def rent(**attrs)
    TudlaAccounting::RecurringEntry.new(organization: organization, name: "Rent", particulars: "Office rent", frequency: "monthly",
                                        starts_on: Date.new(2026, 1, 1), day_of_month: 1, **attrs).tap do |record|
      record.lines.build(account: account("6100"), tally: :debit, amount_cents: 1_000_00)
      record.lines.build(account: account("1010"), tally: :credit, amount_cents: 1_000_00)
      record.save!
    end
  end

  it "makes every entry due, catching up, as drafts from the template, once however often it runs" do
    template = rent
    result = described_class.call(organization: organization, as_of: Date.new(2026, 3, 15))

    expect(result.created.map { |entry| entry.transacted_at.to_date }).to eq([ Date.new(2026, 1, 1), Date.new(2026, 2, 1), Date.new(2026, 3, 1) ])
    expect(result.created).to all(be_draft)
    expect(result.created.first).to have_attributes(source: template, particulars: "Office rent", idempotency_key: "recurring:#{template.id}:2026-01-01")
    expect(template.reload).to have_attributes(next_on: Date.new(2026, 4, 1), occurrences_count: 3, last_problem: nil)

    expect(described_class.call(as_of: Date.new(2026, 3, 15)).created).to be_empty
    expect(TudlaAccounting::Entry.where(source: template).count).to eq(3)
    expect(TudlaAccounting::AuditEvent.where(action: "recurring_entry.generated").count).to eq(3)
  end

  it "posts them when the template says so, keeping a draft and the reason when it can't" do
    template = rent(post_automatically: true, starts_on: Date.new(2026, 12, 1))
    result = described_class.call(as_of: Date.new(2027, 1, 5))

    expect(result.posted.map { |entry| entry.transacted_at.to_date }).to eq([ Date.new(2026, 12, 1) ])
    expect(result.created.last).to be_draft # no 2027 yet
    expect(result.problems).to eq([ "Rent: 1 Jan 2027: left as a draft: no valid period found for the posted date" ])
    expect(template.reload).to have_attributes(next_on: Date.new(2027, 2, 1), last_problem: "1 Jan 2027: left as a draft: no valid period found for the posted date")
  end

  it "stops a template whose entry can't be made, to try again next time" do
    template = rent
    account("6100").update_columns(active: false) # made inactive behind the template's back
    result = described_class.call(as_of: Date.new(2026, 2, 15))

    expect(result.created).to be_empty
    expect(result.problems).to eq([ "Rent: 1 Jan 2026: account 6100 is inactive" ])
    expect(template.reload).to have_attributes(next_on: Date.new(2026, 1, 1), last_problem: "1 Jan 2026: account 6100 is inactive")
  end

  it "skips inactive templates and other organizations' when asked for one" do
    rent(active: false)
    other = create(:organization, currency: "USD")
    expect(described_class.call(organization: other, as_of: Date.new(2026, 3, 1)).created).to be_empty
    expect(described_class.call(organization: organization, as_of: Date.new(2026, 3, 1)).created).to be_empty
  end

  it "reverses each accrual on the first of the next month when posted" do
    template = rent(post_automatically: true, reverse_next_month: true)
    template.lines.last.update!(account: account("2300"))
    entry = described_class.call(as_of: Date.new(2026, 1, 1)).posted.sole
    expect(entry.reversal).to have_attributes(posted_at: Time.zone.local(2026, 2, 1))
  end

  it "runs from the job for every organization, as the recurring entries actor" do
    rent
    TudlaAccounting::RecurringEntriesJob.perform_now("2026-01-01")
    expect(TudlaAccounting::AuditEvent.where(action: "recurring_entry.generated").sole.actor_label).to eq("Recurring entries")
  end
end
