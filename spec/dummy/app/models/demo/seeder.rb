require "csv"

# Seeds Demo Co: last year and this year, a small chart of accounts, GST, a department
# dimension, a couple of hundred posted entries up to today, a few drafts, the first half
# of last year closed, a bank statement for the operating account, recurring entries,
# this year's budget, customers with invoices on account and their payments (the engine's
# contacts, invoices and payments) and a recurring invoice, a supplier's bills, and a BAS with last quarter's
# filed. Returns the organization; running it again returns the existing one, only
# adding the years' periods up to this one if the year has turned since it was seeded.
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
        @organization = Organization.find_by(name: self.class::NAME)
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
      TudlaAccounting::PeriodCreator.call(organization, year) or raise "Couldn't create #{organization.name}'s #{year} periods (see the log)"
    end
  end

  def seed
    @organization = Organization.create!(name: NAME, currency: CURRENCY)
    create_periods
    create_accounts
    @gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: accounts["2200"])
    @gstp = TudlaAccounting::TaxCode.create!(organization: organization, code: "GSTP", name: "GST on purchases", rate: "0.1", kind: :purchases, account: accounts["2200"])
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
    add_customer_accounts
    add_supplier_bills
    add_tax_return
  end

  def create_accounts
    TudlaAccounting::AccountsCreator.call([
      { code: "1000", name: "Assets", category: "asset", children: [
        { code: "1010", name: "Cash and bank", category: "asset", children: [
          { code: "1011", name: "Operating account", category: "asset" }, { code: "1012", name: "Savings account", category: "asset" } ] },
        { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "1500", name: "Equipment", category: "asset" } ] },
      { code: "2000", name: "Liabilities", category: "liability", children: [
        { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2150", name: "Accrued expenses", category: "liability" },
        { code: "2200", name: "GST", category: "liability" }, { code: "2500", name: "Loan", category: "liability" } ] },
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
      entry.particulars = "Invoice #{@invoice_number += 1} – #{self.class::CUSTOMERS.sample(random: random)} (#{accounts[income].name.downcase})"
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
    draft(date, &).tap { |entry| entry.post(at) }
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
    entry.details.build(account: account, tally: tally, amount_cents: cents, currency: organization.currency, organization: organization, **extra)
  end

  # From next month: software, posted automatically, and an accrual for the month's rent
  # before the landlord's invoice comes, at each month's end, as drafts to check.
  def add_recurring_entries
    first = today.next_month.beginning_of_month
    [ [ "Software subscriptions", "Design and accounting software", 1, true, false, [ [ "6020", :debit, 249_00 ], [ "1011", :credit, 249_00 ] ] ],
      [ "Rent accrual", "Rent for the month, not yet invoiced", nil, false, true, [ [ "6010", :debit, 1_800_00 ], [ "2150", :credit, 1_800_00 ] ] ] ]
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

  # Invoices on account to four customers over the last three months, due in 30 days,
  # each paid 25 days later, except that Globex pays half and Umbrella nothing, so the
  # aging report and statements have something to show; and a draft for Initech today.
  # Their own random numbers, so the rest of the demo stays as it was.
  def add_customer_accounts
    hours = Random.new(7)
    customers = CUSTOMERS.first(4).map do |name|
      TudlaAccounting::Contact.create!(organization: organization, name: name, kind: "customer", payment_terms_days: 30, email: "accounts@#{name.parameterize}.example",
                                       address: "#{name.length * 7} #{name} Way\nSydney NSW 2000", default_account: accounts["4010"], default_tax_code: @gst)
    end
    start = today.prev_month(3).beginning_of_month
    invoices = customers.each_with_index.flat_map do |customer, index|
      (0..2).map { |month| [ start.next_month(month) + (index * 6).days, customer ] }.select { |date, _| date <= today }
    end
    # Approved in date order, so they are numbered in it.
    invoices.sort_by(&:first).each do |date, customer|
      invoice = consulting_invoice(customer, date, hours.rand(4..20)).approve!
      paid_on = date + 25
      next if customer.name == "Umbrella" || paid_on > today

      paid = customer.name == "Globex" ? invoice.total_cents / 2 : invoice.total_cents
      TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: customer, account: accounts["1011"], paid_on: paid_on,
                                       amount_cents: paid, reference: "EFT #{invoice.number_label}", applications: [ { document: invoice, amount_cents: paid } ])
    end
    consulting_invoice(customers.third, today, 6)
    add_recurring_invoice(customers.first)
  end

  # Northwind's support retainer from next month, drafts to check, tagged ENG.
  def add_recurring_invoice(customer)
    template = TudlaAccounting::RecurringInvoice.new(organization: organization, name: "Support retainer", contact: customer, frequency: "monthly", day_of_month: 1,
                                                     starts_on: today.next_month.beginning_of_month, notes: "Monthly support, as agreed.")
    template.lines.build(description: "Support retainer", quantity: 1, unit_price_cents: 1_200_00, account: accounts["4020"], tax_code: @gst, dimension_value_ids: [ team("ENG").id ])
    template.save!
  end

  def team(code) = @teams.find { |value| value.code == code }

  def consulting_invoice(customer, date, hours)
    TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: customer, issued_on: date, due_on: customer.due_on(date),
                                      notes: "Please pay within 30 days to account 123-456 789012, quoting the invoice number.",
                                      lines_attributes: [ { description: "Consulting – #{date.strftime('%B %Y')}", quantity: hours, unit_price_cents: 150_00,
                                                            account: accounts["4010"], tax_code: @gst, dimension_value_ids: [ team("ENG").id ] } ])
  end

  # A software supplier's bills, on the first of last month and this month, not yet paid.
  def add_supplier_bills
    supplier = TudlaAccounting::Contact.create!(organization: organization, name: "Cloudware", kind: "supplier", payment_terms_days: 14,
                                                default_account: accounts["6020"], default_tax_code: @gstp)
    [ today.prev_month.beginning_of_month, today.beginning_of_month ].each do |date|
      TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: date, due_on: supplier.due_on(date), reference: "CW-#{date.strftime('%y%m')}",
                                        tax_inclusive: true, lines_attributes: [ { description: "Team plan, #{date.strftime('%B')}", quantity: 5, unit_price_cents: 33_00,
                                                                                   account: accounts["6020"], tax_code: @gstp, dimension_value_ids: [ team("ENG").id ] } ]).approve!
    end
  end

  # A BAS mapped to the GST code and the wages account, with last quarter's filed.
  def add_tax_return
    bas = TudlaAccounting::TaxReturnForm.from_template!(organization, "au_bas")
    box = ->(label) { bas.boxes.find_by!(label: label) }
    box.call("G1").parts.create!(source: "tax_code_gross", tax_code: @gst)
    box.call("1A").parts.create!(source: "tax_code_tax", tax_code: @gst)
    box.call("G11").parts.create!(source: "tax_code_gross", tax_code: @gstp)
    box.call("1B").parts.create!(source: "tax_code_tax", tax_code: @gstp)
    box.call("W1").parts.create!(source: "account", account: accounts["6040"])
    quarter = today.beginning_of_quarter.prev_day.beginning_of_quarter
    months = [ quarter, quarter.end_of_quarter ].map { |date| TudlaAccounting::Period.leaf_periods_for_date(organization, date.in_time_zone(zone).change(hour: 12)).first }
    TudlaAccounting::FiledTaxReturn.file!(bas.reload, from: months.first.from_date, thru: months.last.thru_date)
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
