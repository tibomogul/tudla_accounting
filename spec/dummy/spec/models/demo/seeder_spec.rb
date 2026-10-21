require "rails_helper"

RSpec.describe Demo::Seeder do
  around { |example| travel_to(Time.zone.local(2026, 6, 15, 9)) { example.run } }

  it "seeds Demo Co's books once, balanced" do
    organization = described_class.call(entries: 30)

    expect(organization).to have_attributes(name: "Demo Co", currency: "USD")
    expect(described_class.call(entries: 30)).to eq(organization)
    expect(Organization.where(name: "Demo Co").count).to eq(1)

    entries = TudlaAccounting::Entry.where(organization: organization)
    expect(entries.where.not(posted_at: nil).count).to eq(54) # 30, the owner's capital, 12 invoices on account with 9 payments, and 2 bills
    expect(entries.where(posted_at: nil).count).to eq(3)
    expect(entries.maximum(:transacted_at)).to be <= Time.current
    expect(entries.pluck(:particulars)).to include(a_string_starting_with("Invoice "))
    expect(TudlaAccounting::BalanceRebuilder.new(organization).differences).to be_empty
  end

  it "numbers the invoices, drafts included, without gaps or repeats, in date order" do
    organization = described_class.call(entries: 30)

    invoices = TudlaAccounting::Entry.where(organization: organization).order(:transacted_at, :id).pluck(:particulars).filter_map { |text| text[/\AInvoice (\d+)/, 1]&.to_i }
    expect(invoices).to eq((1000...(1000 + invoices.size)).to_a)
  end

  it "carries last year's profit, so this year's balance sheet balances" do
    organization = described_class.call(entries: 30)

    month = TudlaAccounting::Period.leaf_periods_for_date(organization, Time.current).first
    expect(TudlaAccounting::Reports::BalanceSheet.new(organization, month)).to be_balanced
    retained_earnings = TudlaAccounting::Account.find_by(organization: organization, code: "3900")
    expect(TudlaAccounting::Balance.peek(retained_earnings, month).ending_amount_cents).to be_positive
  end

  it "marks Demo Co's receivables, payables and retained earnings accounts" do
    organization = described_class.call(entries: 30)

    roles = TudlaAccounting::Account.where(organization: organization).where.not(role: nil).pluck(:role, :code).to_h
    expect(roles).to eq("receivable" => "1100", "payable" => "2100", "retained_earnings" => "3900")
  end

  it "closes the first half of last year" do
    organization = described_class.call(entries: 30)

    months = TudlaAccounting::Period.where(organization: organization, children_count: 0).order(:from_date)
    expect(months.first(6)).to all(be_closed)
    expect(months.drop(6)).to all(have_attributes(closed?: false))
  end

  it "imports last month's statement for the operating account, with lines the books don't have" do
    organization = described_class.call(entries: 30)

    account = TudlaAccounting::Account.find_by(organization: organization, code: "1011")
    lines = TudlaAccounting::BankStatementLine.where(account: account)
    expect(lines.pluck(:description)).to include("Account keeping fee", "Interest")
    expect(lines.pluck(:occurred_on)).to all(be_between(Date.new(2026, 5, 1), Date.new(2026, 5, 31)))
  end

  it "sets up recurring entries starting next month" do
    organization = described_class.call(entries: 30)

    templates = TudlaAccounting::RecurringEntry.where(organization: organization).order(:name)
    expect(templates.map { |template| [ template.name, template.schedule_label, template.next_on ] }).to eq([
      [ "Rent accrual", "Every month on the last day", Date.new(2026, 7, 31) ],
      [ "Software subscriptions", "Every month on the 1st", Date.new(2026, 7, 1) ]
    ])
  end

  it "budgets this year from last year's results" do
    organization = described_class.call(entries: 60)

    budget = TudlaAccounting::Budget.find_by!(organization: organization)
    expect(budget).to have_attributes(name: "Plan", main: true, period: TudlaAccounting::Period.periods_for_date(organization, Date.new(2026, 1, 1)).roots.first)
    expect(budget.lines).not_to be_empty
    expect(budget.lines.map(&:amount_cents)).to all(satisfy { |cents| (cents % 100).zero? })
  end

  it "has customers owing for invoices on account, Globex paying half and Umbrella nothing" do
    organization = described_class.call(entries: 30)

    aging = TudlaAccounting::AgingReportGenerator.call(organization: organization, report_type: :receivable, as_of_date: Date.current)
    expect(aging[:summary].values.map { |party| party[:related_party].name }).to contain_exactly("Globex", "Umbrella")
    expect(TudlaAccounting::PartyStatement.parties(organization, :receivable).map(&:name)).to eq(%w[Globex Initech Northwind Umbrella])
    northwind = TudlaAccounting::Contact.find_by!(organization: organization, name: "Northwind")
    statement = TudlaAccounting::PartyStatement.call(organization: organization, type: :receivable, party: northwind, from: Date.new(2026, 3, 1), thru: Date.current)
    expect(statement.lines.map(&:kind)).to eq(%w[Invoice Payment Invoice Payment Invoice Payment])
    expect(statement).to have_attributes(opening: Money.new(0, "USD"), closing: Money.new(0, "USD"))
  end

  it "keeps the customers and a supplier as contacts, with the engine's invoices, bills and payments" do
    organization = described_class.call(entries: 30)

    contacts = TudlaAccounting::Contact.where(organization: organization).order(:name)
    expect(contacts.map { |contact| [ contact.name, contact.kind ] }).to eq([ %w[Cloudware supplier], %w[Globex customer], %w[Initech customer], %w[Northwind customer], %w[Umbrella customer] ])
    documents = TudlaAccounting::Document.where(organization: organization)
    expect(documents.sales.approved.order(:number).pluck(:number_label)).to eq((1..12).map { |number| format("INV-%04d", number) })
    expect(documents.sales.approved.order(:number).pluck(:issued_on)).to eq(documents.sales.approved.order(:issued_on, :number).pluck(:issued_on)) # in date order
    expect(documents.where(status: "draft").sole).to have_attributes(kind: "sales_invoice", issued_on: Date.current, contact: contacts.find_by!(name: "Initech"))
    expect(documents.purchases.approved.map(&:total)).to eq([ Money.new(165_00, "USD") ] * 2)
    paid = documents.sales.approved.with_open_cents.to_a.group_by(&:payment_status)
    expect(paid.keys).to contain_exactly("paid", "part_paid", "unpaid")
    expect(TudlaAccounting::Payment.where(organization: organization).received.count).to eq(9)
  end

  it "sets up a BAS, with last quarter's filed as the books still give it" do
    organization = described_class.call(entries: 60)

    filed = TudlaAccounting::FiledTaxReturn.find_by!(organization: organization)
    expect(filed).to have_attributes(from_date: Time.zone.local(2026, 1, 1), basis: "accrual", filed_by: "Demo seed")
    expect(filed.thru_date.to_date).to eq(Date.new(2026, 3, 31))
    expect(filed.figures.to_h { |box| [ box["label"], box["cents"] ] }.values_at("G1", "1A")).to all(be_positive)
    expect(filed.changes).to be_empty
  end

  it "attaches the landlord's receipt to the latest rent payments" do
    organization = described_class.call(entries: 60)

    rent = TudlaAccounting::Detail.where(account: TudlaAccounting::Account.find_by(organization: organization, code: "6010")).select(:entry_id)
    attached = TudlaAccounting::Entry.where(id: rent).joins(:attachments_attachments).distinct.to_a
    expect(attached.size).to be_between(1, 3)
    receipt = attached.first.attachments.first
    expect(receipt).to have_attributes(content_type: "application/pdf")
    expect(receipt.filename.to_s).to match(/\Arent-receipt-\d{4}-\d{2}-\d{2}\.pdf\z/)
    expect(receipt.download).to include("(Receipt: Rent - ")
  end

  context "when the engine keeps its books in another time zone than the app's" do
    around do |example|
      zone = TudlaAccounting.configuration.time_zone
      TudlaAccounting.configuration.time_zone = "Pacific/Auckland"
      example.run
    ensure
      TudlaAccounting.configuration.time_zone = zone
    end

    it "dates the entries and the statement in the engine's" do
      organization = described_class.call(entries: 30)

      auckland = ActiveSupport::TimeZone["Pacific/Auckland"]
      times = TudlaAccounting::Entry.where(organization: organization).where.not(posted_at: nil).pluck(:transacted_at).map { |time| time.in_time_zone(auckland) }
      expect(times.map(&:hour)).to all(eq(12).or(eq(0))) # invoices, bills and payments are dated at the start of their day
      account = TudlaAccounting::Account.find_by(organization: organization, code: "1011")
      expect(TudlaAccounting::BankStatementLine.where(account: account).pluck(:occurred_on)).to all(be_between(Date.new(2026, 5, 1), Date.new(2026, 5, 31)))
      expect(TudlaAccounting::BalanceRebuilder.new(organization).differences).to be_empty
    end
  end

  it "adds the new year's periods to books seeded last year" do
    organization = described_class.call(entries: 30)
    entry_count = TudlaAccounting::Entry.where(organization: organization).count

    travel_back
    travel_to(Time.zone.local(2027, 1, 5, 9))
    expect(described_class.call).to eq(organization)
    expect(TudlaAccounting::Period.leaf_periods_for_date(organization, Time.current)).to exist
    expect(TudlaAccounting::Entry.where(organization: organization).count).to eq(entry_count)
  end

  it "fills in every year since, however long ago the books were seeded" do
    organization = described_class.call(entries: 30)
    entry_count = TudlaAccounting::Entry.where(organization: organization).count

    travel_back
    travel_to(Time.zone.local(2028, 3, 1, 9))
    expect(described_class.call).to eq(organization)
    years = TudlaAccounting::Period.roots.where(organization: organization).order(:from_date).map { |year| year.from_date.year }
    expect(years).to eq([ 2025, 2026, 2027, 2028 ])
    expect(TudlaAccounting::Entry.where(organization: organization).count).to eq(entry_count)
  end
end
