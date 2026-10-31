# Seeds Demo GmbH, books kept in euros, to show what Demo Co (in dollars) can't: amounts
# written 1.234,56, and dollars as the foreign currency. Last year and this year, Demo
# Co's chart of accounts with a dollar bank account and an exchange gains account, VAT at
# 19% and 7%, the same mix of posted entries (fewer of them), and invoices on account to
# two customers in euros and one in dollars: the dollar invoices at their own rates, the
# first paid into the dollar account at another (an exchange gain), the second still
# owed, as is Rossi's; and a supplier's bill to pay. Like Demo::Seeder, running it again
# returns the existing books, only adding the new year's periods.
class Demo::EuroSeeder < Demo::Seeder
  NAME = "Demo GmbH"
  CURRENCY = "EUR"
  CUSTOMERS = [ "Müller AG", "Rossi S.p.A.", "Acme Inc.", "Dupont SA" ].freeze

  def initialize(entries: 80)
    super
  end

  private

  def seed
    @organization = Organization.create!(name: NAME, currency: CURRENCY)
    create_periods
    create_accounts
    @gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "VAT19", name: "VAT", rate: "0.19", kind: :sales, account: accounts["2200"])
    @reduced = TudlaAccounting::TaxCode.create!(organization: organization, code: "VAT7", name: "VAT reduced", rate: "0.07", kind: :sales, account: accounts["2200"])
    @input = TudlaAccounting::TaxCode.create!(organization: organization, code: "IN19", name: "Input VAT", rate: "0.19", kind: :purchases, account: accounts["2200"])
    department = TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department")
    @teams = %w[SALES ENG OPS ADMIN].map { |code| department.dimension_values.create!(code: code, name: code.capitalize) }

    first_day = Date.new(years.first, 1, 1)
    post(first_day) { |entry| capital(entry) }
    days = (first_day..today).to_a
    Array.new(@entry_count) { days[random.rand(days.size)] }.sort.each_with_index { |date, index| post(date) { |entry| build_lines(entry, index) } }

    add_customer_accounts
    add_supplier_bill
  end

  # Demo Co's chart, its tax account named for VAT, with a bank account in dollars and an
  # account for the gains and losses on settling them.
  def create_accounts
    super
    accounts["2200"].update!(name: "VAT")
    accounts["1020"] = TudlaAccounting::Account.create!(organization: organization, parent: accounts["1010"], code: "1020", name: "USD account", category: "asset", currency: "USD")
    accounts["4900"] = TudlaAccounting::Account.create!(organization: organization, parent: accounts["4000"], code: "4900", name: "Exchange gains and losses", category: "income")
    TudlaAccounting::AccountRoleAssigner.save!(accounts["4900"], "realized_fx_gain")
  end

  # Over the last three months: Müller's consulting, by the hour and in part hours, each
  # paid three weeks later; Rossi's books, at the reduced rate, not paid; and Acme's in
  # dollars, without VAT (an export), the first paid into the dollar account at a better
  # rate than it was invoiced at, the second not yet.
  def add_customer_accounts
    mueller, rossi, acme = CUSTOMERS.first(3).map do |name|
      TudlaAccounting::Contact.create!(organization: organization, name: name, kind: "customer", payment_terms_days: 30, email: "accounts@#{name.parameterize}.example",
                                       currency: (name == "Acme Inc." ? "USD" : CURRENCY), default_account: accounts["4010"])
    end
    start = today.prev_month(3).beginning_of_month
    # [ date, customer, lines, currency and rate, when paid: [ days later, into, at rate ] ]
    invoices = [ 7.5, 12.5, 2.5 ].each_with_index.map do |hours, month|
      date = start.next_month(month) + 4
      [ date, mueller, [ invoice_line("Consulting – #{date.strftime('%B %Y')}", hours, 125_00, @gst) ], {}, [ 21, accounts["1011"], nil ] ]
    end
    invoices << [ start + 10, rossi, [ invoice_line("Reference books", 3, 49_90, @reduced), invoice_line("Workshop", 1, 1_250_00, @gst) ], {}, nil ]
    invoices << [ start + 15, acme, [ invoice_line("Integration work", 20, 140_00, nil) ], { currency: "USD", exchange_rate: BigDecimal("0.9150") }, [ 30, accounts["1020"], BigDecimal("0.9310") ] ]
    invoices << [ start.next_month + 15, acme, [ invoice_line("Integration work", 20, 140_00, nil) ], { currency: "USD", exchange_rate: BigDecimal("0.9230") }, nil ]

    # Approved in date order, so they are numbered in it; then paid.
    approved = invoices.select { |date, *| date <= today }.sort_by(&:first).map do |date, customer, lines, foreign, paid|
      [ sales_invoice(customer, date, lines, **foreign).approve!, paid ]
    end
    approved.each do |invoice, (days, account, rate)|
      next if days.nil? || invoice.issued_on + days > today

      TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: invoice.contact, account: account, paid_on: invoice.issued_on + days, exchange_rate: rate,
                                       amount_cents: invoice.total_cents, reference: "Transfer #{invoice.number_label}", applications: [ { document: invoice, amount_cents: invoice.total_cents } ])
    end
  end

  # A hosting company's bill from the first of this month, not yet paid.
  def add_supplier_bill
    supplier = TudlaAccounting::Contact.create!(organization: organization, name: "Cloudhaus GmbH", kind: "supplier", payment_terms_days: 14,
                                                default_account: accounts["6020"], default_tax_code: @input)
    date = today.beginning_of_month
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: date, due_on: supplier.due_on(date), reference: "CH-#{date.strftime('%y%m')}",
                                      lines_attributes: [ invoice_line("Hosting, #{date.strftime('%B')}", 1, 1_480_00, @input, account: accounts["6020"]) ]).approve!
  end

  def sales_invoice(customer, date, lines, **foreign)
    TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: customer, issued_on: date, due_on: customer.due_on(date),
                                      notes: "Bitte überweisen Sie innerhalb von 30 Tagen auf DE89 3704 0044 0532 0130 00.", lines_attributes: lines, **foreign)
  end

  def invoice_line(description, quantity, unit_price_cents, tax_code, account: accounts["4010"])
    { description: description, quantity: quantity, unit_price_cents: unit_price_cents, account: account, tax_code: tax_code, dimension_value_ids: [ team("ENG").id ] }
  end
end
