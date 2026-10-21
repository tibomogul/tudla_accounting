require "csv"

# Seeds Demo Co: last year and this year, a small chart of accounts, GST, a department
# dimension, a couple of hundred posted entries up to today, a few drafts, the first half
# of last year closed, a bank statement for the operating account, recurring entries
# and this year's budget. Returns the organization; running it again returns the
# existing one, only adding the years' periods up to this one if the year has turned
# since it was seeded.
#
# The name is the demo's identity: an organization someone else names "Demo Co" is
# taken for the demo. That's fine in the dummy app.
class Demo::Seeder
  NAME = "Demo Co"
  CURRENCY = "USD"
  CUSTOMERS = [ "Northwind", "Globex", "Initech", "Umbrella", "Stark Industries", "Wayne Enterprises" ].freeze
  EXPENSES = { "6010" => "Rent", "6020" => "Software subscriptions", "6030" => "Travel", "6040" => "Wages" }.freeze

  def self.call(...) = new(...).call

  def initialize(entries: 200)
    @entry_count = entries
    @random = Random.new(42)
    @invoice_number = 999
  end

  def call
    TudlaAccounting::Current.set(actor: "Demo seed") do
      ActiveRecord::Base.transaction do
        # Two clicks on the demo button at once mustn't seed Demo Co twice.
        ActiveRecord::Base.with_connection { |connection| connection.execute("SELECT pg_advisory_xact_lock(hashtext('tudla_demo_seed'))") }
        @organization = Organization.find_by(name: NAME)
        organization ? create_periods : seed
        organization
      end
    end
  end

  private

  attr_reader :organization, :accounts, :random

  # Dates are the engine's, as its periods are: midday on 1 January must fall in January
  # whatever the app's own time zone.
  def zone = ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone]
  def today = zone.today

  def years = [ today.year - 1, today.year ]

  # Adds the financial years from the books' latest up to this one, so there is no gap
  # however long it's been since the demo was seeded; new books start at last year.
  def create_periods
    latest = TudlaAccounting::Period.roots.where(organization: organization).maximum(:thru_date)
    first = latest ? latest.in_time_zone(zone).year + 1 : years.first
    (first..years.last).each do |year|
      TudlaAccounting::PeriodCreator.call(organization, year) or raise "Couldn't create #{NAME}'s #{year} periods (see the log)"
    end
  end

  def seed
    @organization = Organization.create!(name: NAME, currency: CURRENCY)
    create_periods
    create_accounts
    @gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: accounts["2200"])
    department = TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department")
    @teams = %w[SALES ENG OPS ADMIN].map { |code| department.dimension_values.create!(code: code, name: code.capitalize) }

    first_day = Date.new(years.first, 1, 1)
    post(first_day) { |entry| capital(entry) }
    days = (first_day..today).to_a
    dates = Array.new(@entry_count) { days[random.rand(days.size)] }.sort # so invoice numbers run in date order
    dates.each_with_index { |date, index| post(date) { |entry| build_lines(entry, index) } }
    # Today's drafts: an invoice (taking the next number), an expense and another invoice.
    [ 0, 5, 1 ].each { |kind| draft(today) { |entry| build_lines(entry, kind) } }

    close_first_half_of_last_year
    import_bank_statement
    attach_receipts
    add_recurring_entries
    add_budget
  end

  def create_accounts
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Assets", category: "asset", children: [
        { code: "1010", name: "Cash and bank", category: "asset", children: [
          { code: "1011", name: "Operating account", category: "asset" }, { code: "1012", name: "Savings account", category: "asset" } ] },
        { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "1500", name: "Equipment", category: "asset" } ] },
      { code: "2000", name: "Liabilities", category: "liability", children: [
        { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2200", name: "GST", category: "liability" },
        { code: "2500", name: "Loan", category: "liability" } ] },
      { code: "3000", name: "Equity", category: "equity", children: [
        { code: "3100", name: "Owner's capital", category: "equity" }, { code: "3900", name: "Retained earnings", category: "equity", role: "retained_earnings" } ] },
      { code: "4000", name: "Income", category: "income", children: [
        { code: "4010", name: "Consulting", category: "income" }, { code: "4020", name: "Subscriptions", category: "income" } ] },
      { code: "6000", name: "Expenses", category: "expense", children: [
        { code: "6010", name: "Rent", category: "expense" }, { code: "6020", name: "Software", category: "expense" },
        { code: "6030", name: "Travel", category: "expense" }, { code: "6040", name: "Wages", category: "expense" } ] }
    ], organization)
    @accounts = TudlaAccounting::Account.where(organization: organization).index_by(&:code)
    accounts["1500"].update!(cash_flow_activity: :investing)
    accounts["2500"].update!(cash_flow_activity: :financing)
  end

  def capital(entry)
    entry.particulars = "Owner's capital"
    line(entry, accounts["1011"], :debit, 50_000_00)
    line(entry, accounts["3100"], :credit, 50_000_00)
  end

  # The index picks the kind of entry: of every ten, five sales, four expenses and one
  # equipment purchase or loan.
  def build_lines(entry, index)
    bank = accounts[%w[1011 1012].sample(random: random)]
    month = entry.transacted_at.strftime("%B")
    case index % 10
    when 0..4 # a sale with GST, tagged
      net = random.rand(100_00..5_000_00)
      tax = net / 10
      income = %w[4010 4020].sample(random: random)
      entry.particulars = "Invoice #{@invoice_number += 1} – #{CUSTOMERS.sample(random: random)} (#{accounts[income].name.downcase})"
      entry.reference = "INV-#{@invoice_number}"
      line(entry, bank, :debit, net + tax)
      sale = line(entry, accounts[income], :credit, net, tax_code: @gst, tax_role: :base)
      sale.tags.build(dimension_value: @teams.sample(random: random))
      line(entry, accounts["2200"], :credit, tax, tax_code: @gst, tax_role: :tax)
    when 5..8 # an expense, tagged
      cents = random.rand(10_00..2_000_00)
      code = EXPENSES.keys.sample(random: random)
      team = @teams.sample(random: random)
      entry.particulars = "#{EXPENSES[code]} – #{month} (#{team.name})"
      line(entry, accounts[code], :debit, cents).tags.build(dimension_value: team)
      line(entry, bank, :credit, cents)
    else # equipment bought, or a loan drawn
      cents = random.rand(500_00..5_000_00)
      equipment = random.rand(2).zero?
      entry.particulars = equipment ? "Laptops and monitors" : "Loan drawdown"
      debit, credit = equipment ? [ accounts["1500"], bank ] : [ bank, accounts["2500"] ]
      line(entry, debit, :debit, cents)
      line(entry, credit, :credit, cents)
    end
  end

  def post(date, &)
    at = noon(date)
    draft(date, &).post(at)
  end

  def draft(date)
    entry = TudlaAccounting::Entry.new(organization: organization, transacted_at: noon(date))
    yield entry
    entry.save!
    entry
  end

  # Midday, but never later than now: nothing is dated in the future.
  def noon(date) = [ date.in_time_zone(zone).change(hour: 12), Time.current ].min

  def line(entry, account, tally, cents, **extra)
    entry.details.build(account: account, tally: tally, amount_cents: cents, currency: CURRENCY, organization: organization, **extra)
  end

  # From next month: software, posted automatically, and an accrual for the month's rent
  # before the landlord's invoice comes, at each month's end, as drafts to check.
  def add_recurring_entries
    first = today.next_month.beginning_of_month
    [ [ "Software subscriptions", "Design and accounting software", 1, true, false, [ [ "6020", :debit, 249_00 ], [ "1011", :credit, 249_00 ] ] ],
      [ "Rent accrual", "Rent for the month, not yet invoiced", nil, false, true, [ [ "6010", :debit, 1_800_00 ], [ "2100", :credit, 1_800_00 ] ] ] ]
      .each do |name, particulars, day, post, reverse, lines|
        template = TudlaAccounting::RecurringEntry.new(organization: organization, name: name, particulars: particulars, frequency: "monthly",
                                                       day_of_month: day, starts_on: first, post_automatically: post, reverse_next_month: reverse)
        lines.each { |code, tally, cents| template.lines.build(account: accounts[code], tally: tally, amount_cents: cents) }
        template.save!
      end
  end

  # This year's main budget: last year's results, month for month, plus 10%.
  def add_budget
    last_year, this_year = years.map { |year| TudlaAccounting::Period.periods_for_date(organization, Date.new(year, 1, 1)).roots.first }
    TudlaAccounting::Budget.create!(organization: organization, period: this_year, name: "Plan", main: true).fill_from_actuals!(last_year, percent: 10)
  end

  # The landlord's receipt on the three latest rent payments, when the app has Active Storage.
  def attach_receipts
    return unless TudlaAccounting.attachments?

    rent = TudlaAccounting::Detail.where(account: accounts["6010"]).select(:entry_id)
    TudlaAccounting::Entry.where(id: rent).where.not(posted_at: nil).order(transacted_at: :desc).first(3).each do |entry|
      date = entry.transacted_at.in_time_zone(zone).to_date
      pdf = receipt_pdf("Receipt: #{entry.particulars}, #{date.iso8601}, #{entry.details.find(&:debit?).amount.format}")
      entry.add_attachments!(io: StringIO.new(pdf), filename: "rent-receipt-#{date.iso8601}.pdf", content_type: "application/pdf")
    end
  end

  # A one-page PDF saying text (in ASCII: the built-in font has no en dash).
  def receipt_pdf(text)
    text = ActiveSupport::Inflector.transliterate(text.tr("–", "-"))
    stream = "BT /F1 14 Tf 72 720 Td (#{text.gsub(/[()\\]/) { |c| "\\#{c}" }}) Tj ET"
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
      "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]
    pdf = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map do |object, index|
      pdf.bytesize.tap { pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n" }
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n" << offsets.map { |offset| format("%010d 00000 n \n", offset) }.join
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  end

  # Months close in order, after everything has been posted into them.
  def close_first_half_of_last_year
    year = TudlaAccounting::Period.periods_for_date(organization, Date.new(years.first, 1, 1)).roots.first
    year.children.order(:from_date).first(6).each(&:close!)
  end

  # Last calendar month's statement for the operating account: what the books show going
  # through it, plus a bank fee and some interest the books don't have yet, to reconcile.
  def import_bank_statement
    account = accounts["1011"]
    month = today.prev_month.in_time_zone(zone).all_month
    entries = TudlaAccounting::Entry.where(organization: organization).where.not(posted_at: nil).where(transacted_at: month)
    details = TudlaAccounting::Detail.where(account: account, entry: entries).includes(:entry)
    rows = details.map { |detail| [ detail.entry.transacted_at.in_time_zone(zone).to_date, detail.entry.particulars, detail.debit? ? detail.amount_cents : -detail.amount_cents ] }
    rows << [ month.last.to_date, "Account keeping fee", -15_00 ] << [ month.last.to_date, "Interest", 3_27 ]
    csv = CSV.generate do |out|
      out << %w[Date Description Amount]
      rows.sort_by(&:first).each { |date, text, cents| out << [ date.iso8601, text, format("%.2f", cents / 100.0) ] }
    end

    Tempfile.create([ "demo_statement", ".csv" ]) do |file|
      file.write(csv)
      file.flush
      TudlaAccounting::BankStatementImporter.call(account, file.path)
    end
  end
end
