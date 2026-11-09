require "rails_helper"

RSpec.describe Demo::Seeder do
  around { |example| travel_to(Time.zone.local(2026, 6, 15, 9)) { example.run } }

  it "seeds Demo Co's books once, balanced" do
    organization = described_class.call(entries: 30)

    expect(organization).to have_attributes(name: "Demo Co", currency: "USD")
    expect(described_class.call(entries: 30)).to eq(organization)
    expect(Organization.where(name: "Demo Co").count).to eq(1)

    entries = TudlaAccounting::Entry.where(organization: organization)
    expect(entries.where.not(posted_at: nil).count).to eq(86) # 30, the owner's capital, 12 invoices on account with 9 payments, 2 bills, 4 GST-free sales with their payments, 2 equipment bills, 2 payrolls, a payment to the ATO, 4 gardener's bills with 3 payments, 4 florist's bills paid, and 2 electrician's bills paid
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

  it "sets up recurring entries and a recurring invoice starting next month" do
    organization = described_class.call(entries: 30)

    templates = TudlaAccounting::RecurringEntry.where(organization: organization).order(:name)
    expect(templates.map { |template| [ template.name, template.schedule_label, template.next_on ] }).to eq([
      [ "Rent accrual", "Every month on the last day", Date.new(2026, 7, 31) ],
      [ "Software subscriptions", "Every month on the 1st", Date.new(2026, 7, 1) ]
    ])
    invoice = TudlaAccounting::RecurringInvoice.find_by!(organization: organization)
    expect(invoice).to have_attributes(name: "Support retainer", issue: "draft", next_on: Date.new(2026, 7, 1), total: Money.new(1_320_00, "USD"))
    expect(invoice.contact.name).to eq("Northwind")
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
    expect(TudlaAccounting::PartyStatement.parties(organization, :receivable).map(&:name)).to eq([ "Globex", "Harbour Training College", "Initech", "Kyoto Trading KK", "Northwind", "Umbrella" ])
    northwind = TudlaAccounting::Contact.find_by!(organization: organization, name: "Northwind")
    statement = TudlaAccounting::PartyStatement.call(organization: organization, type: :receivable, party: northwind, from: Date.new(2026, 3, 1), thru: Date.current)
    expect(statement.lines.map(&:kind)).to eq(%w[Invoice Payment Invoice Payment Invoice Payment])
    expect(statement).to have_attributes(opening: Money.new(0, "USD"), closing: Money.new(0, "USD"))
  end

  it "keeps the customers and a supplier as contacts, with the engine's invoices, bills and payments" do
    organization = described_class.call(entries: 30)

    contacts = TudlaAccounting::Contact.where(organization: organization).order(:name)
    expect(contacts.map { |contact| [ contact.name, contact.kind ] }).to eq([ [ "Bright Spark Electrical", "supplier" ], %w[Cloudware supplier], [ "Corner Florist", "supplier" ], %w[Globex customer], [ "Greenleaf Gardening", "supplier" ], [ "Harbour Training College", "customer" ], %w[Initech customer], [ "Kyoto Trading KK", "customer" ], [ "Metro Office Equipment", "supplier" ], %w[Northwind customer], %w[Umbrella customer] ])
    documents = TudlaAccounting::Document.where(organization: organization)
    expect(documents.sales.approved.order(:number).pluck(:number_label)).to eq((1..16).map { |number| format("INV-%04d", number) })
    expect(documents.sales.approved.order(:number).pluck(:issued_on)).to eq(documents.sales.approved.order(:issued_on, :number).pluck(:issued_on)) # in date order
    expect(documents.where(status: "draft").sole).to have_attributes(kind: "sales_invoice", issued_on: Date.current, contact: contacts.find_by!(name: "Initech"))
    expect(documents.purchases.approved.map(&:total)).to match_array(([ Money.new(165_00, "USD"), Money.new(5_500_00, "USD") ] * 2) + ([ Money.new(1_000_00, "USD") ] * 4) + ([ Money.new(2_200_00, "USD") ] * 2) + ([ Money.new(40_00, "USD") ] * 4))
    paid = documents.sales.approved.with_open_cents.to_a.group_by(&:payment_status)
    expect(paid.keys).to contain_exactly("paid", "part_paid", "unpaid")
    expect(TudlaAccounting::Payment.where(organization: organization).received.count).to eq(13)
  end

  it "sets up a BAS, with last quarter's filed as the books still give it" do
    organization = described_class.call(entries: 60)

    filed = TudlaAccounting::FiledTaxReturn.find_by!(organization: organization)
    expect(filed).to have_attributes(from_date: Time.zone.local(2026, 1, 1), basis: "accrual", filed_by: "Demo seed")
    expect(filed.thru_date.to_date).to eq(Date.new(2026, 3, 31))
    expect(filed.figures.to_h { |box| [ box["label"], box["cents"] ] }.values_at("G1", "1A")).to all(be_positive)
    expect(filed.changes).to be_empty
    figures = filed.figures.to_h { |box| [ box["label"], box["cents"] ] }
    expect(figures.values_at("G2", "G3")).to eq([ 2_000_00, 2_000_00 ])
    expect(figures["G10"]).to eq(5_500_00)
    expect(figures["W2"]).to eq(1_600_00)
    expect(figures["W4"]).to eq(470_00) # the gardener paid in March
    expect(figures.values_at("W5", "4")).to eq([ 2_070_00, 2_070_00 ])
    expect(figures["9"]).to eq(figures["8A"] - figures["8B"])
    expect(figures["8A"]).to eq(figures["1A"] + 2_070_00)
    now = TudlaAccounting::TaxReturnCalculator.call(filed.form, from: Time.current.beginning_of_quarter, thru: Time.current.end_of_quarter)
    expect(now[:boxes].find { |row| row.box.label == "W2" }.amount).to eq(Money.new(1_600_00, "USD")) # with the ATO paid this month
  end

  it "pays a supplier with no ABN with tax withheld, for the year-end list by payee, and leaves this month's bill for a pay run; it and the electrician are on the TPAR" do
    organization = described_class.call(entries: 30)

    gardener = TudlaAccounting::Contact.find_by!(organization: organization, name: "Greenleaf Gardening")
    expect(gardener.payment_withholding_code).to have_attributes(code: "NOABN", rate: BigDecimal("0.47"))
    months = TudlaAccounting::Period.where(organization: organization).where.not(ancestry: "/").order(:from_date).to_a
    last_year = TudlaAccounting::Reports::PayeePayments.new(organization, from: months.find { |month| month.from_date.year == 2025 }, thru: months.reverse.find { |month| month.from_date.year == 2025 })
    expect(last_year.payees.map { |payee| [ payee.contact.name, payee.gross.cents, payee.withheld.cents ] }).to eq([ [ "Greenleaf Gardening", 2_000_00, 940_00 ] ])
    expect(last_year.checks("from_supplier").map(&:difference)).to all(be_zero)
    expect(last_year.not_withheld.map { |payment| [ payment.contact.name, payment.amount_cents, payment.not_withheld_reason ] })
      .to eq((9..12).map { |number| [ "Corner Florist", 40_00, "The supply on BILL-#{format('%04d', number)} is $75.00 or less before tax" ] })
    due = TudlaAccounting::PayRun.due(organization, currency: "USD").select { |bill| bill.contact == gardener }
    expect(due.map(&:issued_on)).to eq([ Date.new(2026, 6, 1) ])
    tpar = TudlaAccounting::Reports::TaxablePayments.new(organization, from: last_year.from, thru: last_year.thru)
    expect(tpar.payees.map { |payee| [ payee.contact.name, payee.contact.tax_number, payee.gross.cents, payee.gst.cents, payee.withheld.cents ] })
      .to eq([ [ "Bright Spark Electrical", "51 824 753 556", 4_400_00, 400_00, 0 ], [ "Greenleaf Gardening", nil, 2_000_00, 0, 940_00 ] ])
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
