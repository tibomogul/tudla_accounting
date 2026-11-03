# Seeds Demo Pilipinas Inc., books kept in Philippine pesos (₱): Demo GmbH's books, with
# Philippine VAT (12%, and zero-rated for exports of services) and Filipino customers.
# Bayanihan's consulting is paid three weeks after each invoice; Sampaguita's workshop
# isn't paid yet; and Acme is invoiced in dollars, zero-rated, at the invoices' own rates,
# the first paid into the dollar account at a better one (an exchange gain), the second
# still owed. There is also a hosting company's bill to pay, and a quarterly VAT return
# (BIR Form 2550Q) with last quarter's filed.
#
# It withholds tax as well, from the BIR's starter list of codes: Dakila's consulting at 10%
# (last quarter's bill paid, this month's not) and Matibay's contract work at 2% (not paid),
# for the 2307s and the QAP. Tala withholds 2% from its two payments, one with its
# certificate in and on the SAWT, the other still to chase. The names and TINs are made up.
#
# Like Demo::Seeder, running it again returns the existing books, only adding the new
# year's periods.
class Demo::PesoSeeder < Demo::EuroSeeder
  NAME = "Demo Pilipinas Inc."
  CURRENCY = "PHP"
  CUSTOMERS = [ "Bayanihan Trading Corp.", "Sampaguita Foods Inc.", "Acme Inc.", "Tala Logistics Inc." ].freeze
  PAYMENT_NOTE = "Please pay within 30 days to account 0012-3456-7890, quoting the invoice number."
  SUPPLIER = [ "Ulap Hosting Inc.", "UH", 25_000_00 ].freeze
  # The withholding_agent setting's details, on its 2307s.
  WITHHOLDING_AGENT = { tin: "000-123-456-00000", address: "1 Ayala Avenue, Makati City", zip: "1226", signatory_name: "Maria Santos", signatory_title: "Finance Manager", signatory_tin: "000-987-654-00000" }.freeze

  private

  def seed
    super
    add_tax_return
  end

  def create_accounts
    super
    accounts["1200"] = TudlaAccounting::Account.create!(organization: organization, parent: accounts["1000"], code: "1200", name: "Creditable withholding tax", category: "asset")
    accounts["2300"] = TudlaAccounting::Account.create!(organization: organization, parent: accounts["2000"], code: "2300", name: "Expanded withholding tax payable", category: "liability")
  end

  def create_tax_codes
    @gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "VAT12", name: "VAT", rate: "0.12", kind: :sales, account: accounts["2200"])
    @zero = TudlaAccounting::TaxCode.create!(organization: organization, code: "VATZR", name: "VAT zero-rated", rate: "0", kind: :sales, treatment: :zero_rated)
    @input = TudlaAccounting::TaxCode.create!(organization: organization, code: "IN12", name: "Input VAT", rate: "0.12", kind: :purchases, account: accounts["2200"])
    TudlaAccounting::WithholdingCodeTemplates.add!(organization, "ph_expanded", payable_account: accounts["2300"], creditable_account: accounts["1200"])
  end

  def add_customer_accounts
    bayanihan, sampaguita, acme = customers
    start = today.prev_month(3).beginning_of_month
    invoices = [ 7.5, 12.5, 2.5 ].each_with_index.map do |hours, month|
      date = start.next_month(month) + 4
      [ date, bayanihan, [ invoice_line("Consulting – #{date.strftime('%B %Y')}", hours, 2_500_00, @gst) ], {}, [ 21, accounts["1011"], nil ] ]
    end
    invoices << [ start + 10, sampaguita, [ invoice_line("Bookkeeping workshop", 1, 45_000_00, @gst), invoice_line("Training materials", 6, 850_00, @gst) ], {}, nil ]
    invoices << [ start + 15, acme, [ invoice_line("Integration work", 20, 140_00, @zero) ], { currency: "USD", exchange_rate: BigDecimal("62.85") }, [ 30, accounts["1020"], BigDecimal("63.40") ] ]
    invoices << [ start.next_month + 15, acme, [ invoice_line("Integration work", 20, 140_00, @zero) ], { currency: "USD", exchange_rate: BigDecimal("63.10") }, nil ]
    tala = TudlaAccounting::Contact.create!(organization: organization, name: "Tala Logistics Inc.", kind: "customer", payment_terms_days: 30, email: "accounts@tala-logistics-inc.example",
                                            currency: CURRENCY, default_account: accounts["4010"], tax_number: "000-555-666-00000", address: "5 Made-up Road, Pasig City")
    # The 21st of each of these months, paid a week later, so always by today.
    deliveries = [ start + 20, start.next_month(2) + 20 ]
    invoices += deliveries.map { |date| [ date, tala, [ invoice_line("Logistics consulting", 1, 100_000_00, @gst) ], {}, nil ] }
    approve_and_pay(invoices)
    add_withholding_customer_payments(tala)
  end

  # Tala pays each invoice less 2%, and its certificate for the earlier one has come in.
  def add_withholding_customer_payments(tala)
    code = withholding_code("WC160")
    payments = TudlaAccounting::Document.where(organization: organization, contact: tala).order(:issued_on).map do |invoice|
      TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: tala, account: accounts["1011"], paid_on: invoice.issued_on + 7, reference: "Transfer #{invoice.number_label}",
                                       amount_cents: invoice.total_cents - 2_000_00, withholdings: [ { code: code, withheld_cents: 2_000_00 } ], applications: [ { document: invoice, amount_cents: invoice.total_cents } ])
    end
    payments.first.withheld_taxes.each { |row| row.mark_certificate!(on: payments.first.paid_on + 14) }
  end

  def add_supplier_bill
    start = today.prev_month(3).beginning_of_month
    dakila = withheld_supplier("Dakila Consulting Corp.", "000-222-333-00000", "2 Made-up Street, Quezon City", "WC050")
    matibay = withheld_supplier("Matibay Builders Inc.", "000-333-444-00000", "3 Made-up Avenue, Cebu City", "WC120")
    first = withheld_bill(dakila, start + 7, "Management consulting", 60_000_00)
    TudlaAccounting::Payment.record!(organization: organization, kind: "paid", contact: dakila, account: accounts["1011"], paid_on: first.issued_on + 14, reference: "Transfer #{first.number_label}",
                                     amount_cents: first.amount_due.cents, applications: [ { document: first, amount_cents: first.amount_due.cents } ])
    # This month's, so the reports' default quarter always has both, whatever the day.
    withheld_bill(dakila, today.beginning_of_month, "Management consulting", 60_000_00)
    withheld_bill(matibay, today.beginning_of_month, "Office fit-out", 150_000_00)
    super
  end

  def withheld_supplier(name, tin, address, code)
    TudlaAccounting::Contact.create!(organization: organization, name: name, kind: "supplier", payment_terms_days: 30, tax_number: tin, address: address,
                                     default_account: accounts["6020"], default_tax_code: @input, default_withholding_code: withholding_code(code))
  end

  def withheld_bill(supplier, date, description, cents)
    line = invoice_line(description, 1, cents, @input, account: accounts["6020"]).merge(withholding_code: supplier.default_withholding_code)
    TudlaAccounting::Document.create!(organization: organization, kind: "bill", contact: supplier, issued_on: date, due_on: supplier.due_on(date), lines_attributes: [ line ]).approve!
  end

  def withholding_code(code) = TudlaAccounting::WithholdingCode.find_by!(organization: organization, code: code)

  # A 2550Q with its sales and purchases boxes mapped to the VAT codes, and last quarter's filed.
  def add_tax_return
    form = TudlaAccounting::TaxReturnForm.from_template!(organization, "ph_2550q")
    { "31A" => [ "tax_code_base", @gst ], "31B" => [ "tax_code_tax", @gst ], "32A" => [ "tax_code_base", @zero ],
      "44A" => [ "tax_code_base", @input ], "44B" => [ "tax_code_tax", @input ] }.each do |label, (source, code)|
      form.boxes.find_by!(label: label).parts.create!(source: source, tax_code: code)
    end
    quarter = today.beginning_of_quarter.prev_day.beginning_of_quarter
    months = [ quarter, quarter.end_of_quarter ].map { |date| TudlaAccounting::Period.leaf_periods_for_date(organization, date.in_time_zone(zone).change(hour: 12)).first }
    TudlaAccounting::FiledTaxReturn.file!(form.reload, from: months.first.from_date, thru: months.last.thru_date)
  end
end
