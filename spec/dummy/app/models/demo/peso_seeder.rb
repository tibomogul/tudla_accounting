# Seeds Demo Pilipinas Inc., books kept in Philippine pesos (₱): Demo GmbH's books, with
# Philippine VAT (12%, and zero-rated for exports of services) and Filipino customers.
# Bayanihan's consulting is paid three weeks after each invoice; Sampaguita's workshop
# isn't paid yet; and Acme is invoiced in dollars, zero-rated, at the invoices' own rates,
# the first paid into the dollar account at a better one (an exchange gain), the second
# still owed. There is also a hosting company's bill to pay. Like Demo::Seeder, running it
# again returns the existing books, only adding the new year's periods.
class Demo::PesoSeeder < Demo::EuroSeeder
  NAME = "Demo Pilipinas Inc."
  CURRENCY = "PHP"
  CUSTOMERS = [ "Bayanihan Trading Corp.", "Sampaguita Foods Inc.", "Acme Inc.", "Tala Logistics Inc." ].freeze
  PAYMENT_NOTE = "Please pay within 30 days to account 0012-3456-7890, quoting the invoice number."
  SUPPLIER = [ "Ulap Hosting Inc.", "UH", 25_000_00 ].freeze

  private

  def create_tax_codes
    @gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "VAT12", name: "VAT", rate: "0.12", kind: :sales, account: accounts["2200"])
    @zero = TudlaAccounting::TaxCode.create!(organization: organization, code: "VATZR", name: "VAT zero-rated", rate: "0", kind: :sales)
    @input = TudlaAccounting::TaxCode.create!(organization: organization, code: "IN12", name: "Input VAT", rate: "0.12", kind: :purchases, account: accounts["2200"])
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
    approve_and_pay(invoices)
  end
end
