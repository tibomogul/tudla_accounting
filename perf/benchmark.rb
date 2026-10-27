# Times posting and the engine's reports and pages on a large generated set of books.
#
#   bin/rails runner perf/benchmark.rb              # 2,000 entries over two years
#   ENTRIES=10000 KEEP=1 bin/rails runner perf/benchmark.rb
#
# Runs in its own organization ("Perf Co"), deleted afterwards unless KEEP=1. Prints the
# time and the number of SQL queries for each step. Besides the entries, a quarter as many
# invoices and bills are approved (some in euros), most of them paid, with credit notes,
# refunds, a recurring invoice and a budget.
ENTRY_COUNT = Integer(ENV.fetch("ENTRIES", "2000"))
DOCUMENT_COUNT = ENTRY_COUNT / 4
srand(42)

def measure(label)
  queries = 0
  counter = ->(*, payload) { queries += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].start_with?("SAVEPOINT", "RELEASE") }
  result = nil
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { result = yield }
  seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts format("%-44s %9.3fs %8d queries", label, seconds, queries)
  result
end

def purge(organization)
  TudlaAccounting::DatabaseProtection.allowing_posted_changes do
    scope = ->(model) { model.where(organization_type: organization.class.name, organization_id: organization.id) }
    scope.call(TudlaAccounting::Delivery).delete_all
    scope.call(TudlaAccounting::Document).update_all(credited_document_id: nil)
    scope.call(TudlaAccounting::Document).delete_all # their lines go with them
    scope.call(TudlaAccounting::Payment).delete_all
    TudlaAccounting::RecurringInvoiceLine.where(recurring_invoice: scope.call(TudlaAccounting::RecurringInvoice)).delete_all
    scope.call(TudlaAccounting::RecurringInvoice).delete_all
    scope.call(TudlaAccounting::Contact).delete_all
    scope.call(TudlaAccounting::Budget).delete_all # their lines go with them
    scope.call(TudlaAccounting::BankRule).delete_all
    detail_ids = scope.call(TudlaAccounting::Detail).pluck(:id)
    TudlaAccounting::DetailTag.where(detail_id: detail_ids).delete_all
    TudlaAccounting::BankMatch.where(detail_id: detail_ids).delete_all
    scope.call(TudlaAccounting::BankStatementLine).delete_all
    scope.call(TudlaAccounting::Allocation).delete_all
    TudlaAccounting::CarryingAmountForex.joins(carrying_amount: :detail).where(tudla_accounting_details: { id: detail_ids }).delete_all
    TudlaAccounting::CarryingAmount.where(detail_id: detail_ids).delete_all
    TudlaAccounting::ForeignExchange.where(detail_id: detail_ids).delete_all
    TudlaAccounting::Detail.where(id: detail_ids).delete_all
    scope.call(TudlaAccounting::Balance).delete_all
    scope.call(TudlaAccounting::Entry).delete_all
    scope.call(TudlaAccounting::TaxCode).delete_all
    dimensions = scope.call(TudlaAccounting::Dimension)
    TudlaAccounting::DimensionValue.where(dimension: dimensions).delete_all
    dimensions.delete_all
    scope.call(TudlaAccounting::AuditEvent).delete_all
    scope.call(TudlaAccounting::Sequence).delete_all
    scope.call(TudlaAccounting::Account).update_all(contra_account_id: nil)
    scope.call(TudlaAccounting::Account).delete_all
    scope.call(TudlaAccounting::Period).delete_all
    organization.delete
  end
end

Organization.where(name: "Perf Co").find_each { |old| purge(old) } # left by a run with KEEP=1
organization = Organization.create!(name: "Perf Co", currency: "AUD")
TudlaAccounting::Current.actor = "Benchmark"

puts "Setting up #{ENTRY_COUNT} entries for #{organization.name} (##{organization.id})"
years = [ 2025, 2026 ].map { |year| TudlaAccounting::PeriodCreator.call(organization, year) }
TudlaAccounting::AccountsCreator.call([
  { code: "1000", name: "Assets", category: "asset", children: [
    { code: "1010", name: "Cash and bank", category: "asset", children: (1..3).map { |i| { code: "101#{i}", name: "Bank #{i}", category: "asset" } } },
    { code: "1100", name: "Receivables", category: "asset", role: "receivable" }, { code: "1500", name: "Equipment", category: "asset" } ] },
  { code: "2000", name: "Liabilities", category: "liability", children: [
    { code: "2100", name: "Payables", category: "liability", role: "payable" }, { code: "2200", name: "GST", category: "liability" }, { code: "2500", name: "Loan", category: "liability" } ] },
  { code: "3000", name: "Equity", category: "equity", children: [ { code: "3100", name: "Capital", category: "equity" }, { code: "3900", name: "Retained earnings", category: "equity", role: "retained_earnings" } ] },
  { code: "4000", name: "Income", category: "income", children: (1..4).map { |i| { code: "40#{i}0", name: "Sales #{i}", category: "income" } } },
  { code: "6000", name: "Expenses", category: "expense", children: (1..9).map { |i| { code: "60#{i}0", name: "Expense #{i}", category: "expense" } } }
], organization)
accounts = TudlaAccounting::Account.where(organization: organization).index_by(&:code)
accounts["1500"].update!(cash_flow_activity: :investing)
accounts["2500"].update!(cash_flow_activity: :financing)
gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: accounts["2200"])
gst_paid = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST-P", name: "GST on purchases", rate: "0.1", kind: :purchases, account: accounts["2200"])
department = TudlaAccounting::Dimension.create!(organization: organization, code: "DEPT", name: "Department")
teams = %w[SALES ENG OPS ADMIN].map { |code| department.dimension_values.create!(code: code, name: code.capitalize) }
banks = %w[1011 1012 1013].map { |code| accounts[code] }
sales = %w[4010 4020 4030 4040].map { |code| accounts[code] }
expenses = (1..9).map { |i| accounts["60#{i}0"] }
days = (Date.new(2025, 1, 1)..Date.new(2026, 12, 31)).to_a

line = ->(entry, account, tally, cents, **extra) { entry.details.build(account: account, tally: tally, amount_cents: cents, currency: "AUD", organization: organization, **extra) }
build_entry = lambda do |index|
  at = Time.zone.local(*days.sample.then { |d| [ d.year, d.month, d.day ] })
  entry = TudlaAccounting::Entry.new(organization: organization, transacted_at: at, particulars: "Entry #{index}")
  case index % 10
  when 0..4 # a sale with GST, tagged
    net = rand(100_00..5_000_00)
    tax = net / 10
    line.call(entry, banks.sample, :debit, net + tax)
    sale = line.call(entry, sales.sample, :credit, net, tax_code: gst, tax_role: :base)
    sale.tags.build(dimension_value: teams.sample)
    line.call(entry, accounts["2200"], :credit, tax, tax_code: gst, tax_role: :tax)
  when 5..8 # an expense, tagged
    cents = rand(10_00..2_000_00)
    expense = line.call(entry, expenses.sample, :debit, cents)
    expense.tags.build(dimension_value: teams.sample)
    line.call(entry, banks.sample, :credit, cents)
  else # equipment, a loan or a transfer
    cents = rand(500_00..10_000_00)
    debit, credit = [ [ accounts["1500"], banks.sample ], [ banks.sample, accounts["2500"] ], banks.sample(2) ].sample
    line.call(entry, debit, :debit, cents)
    line.call(entry, credit, :credit, cents)
  end
  entry.save!
  entry
end

entries = measure("create #{ENTRY_COUNT} draft entries") { Array.new(ENTRY_COUNT) { |i| build_entry.call(i) } }
measure("post #{ENTRY_COUNT} entries (random dates)") { entries.each { |entry| entry.post(entry.transacted_at) } }

customers = Array.new(30) do |i|
  TudlaAccounting::Contact.create!(organization: organization, name: "Customer #{i + 1}", kind: "customer", email: "customer#{i + 1}@example.test",
                                   payment_terms_days: [ 7, 14, 30 ].sample, default_account: sales.sample, default_tax_code: gst)
end
suppliers = Array.new(10) do |i|
  TudlaAccounting::Contact.create!(organization: organization, name: "Supplier #{i + 1}", kind: "supplier", email: "supplier#{i + 1}@example.test",
                                   payment_terms_days: 30, default_account: expenses.sample, default_tax_code: gst_paid)
end
document_lines = lambda do |contact, foreign|
  Array.new(rand(1..3)) do
    { description: "Item", quantity: rand(1..5), unit_price_cents: rand(20_00..800_00), account: contact.default_account, tax_code: (contact.default_tax_code unless foreign) }
  end
end
# Seven in ten are invoices; one invoice in twenty is in euros.
documents = measure("approve #{DOCUMENT_COUNT} invoices and bills") do
  Array.new(DOCUMENT_COUNT) do |index|
    invoice = index % 10 < 7
    contact = (invoice ? customers : suppliers).sample
    foreign = invoice && (index % 20).zero?
    issued = days.sample
    TudlaAccounting::Document.create!(organization: organization, kind: invoice ? "sales_invoice" : "bill", contact: contact, issued_on: issued,
                                      due_on: contact.due_on(issued), currency: foreign ? "EUR" : organization.currency, exchange_rate: ("1.6" if foreign),
                                      lines_attributes: document_lines.call(contact, foreign)).tap(&:approve!)
  end
end
# Seven in ten in the organization's currency are paid, one of those in full plus $10, refunded, and
# one in half; one in twenty of the rest gets a credit note.
last_day = days.last
payments = measure("record payments, credit notes and refunds") do
  documents.each_with_index.filter_map do |document, index|
    next if document.foreign?

    if index % 10 >= 7
      next unless (index % 20) == 8

      credit_lines = [ { description: "Credit", quantity: 1, unit_price_cents: 10_00, account: document.lines.first.account, tax_code: document.lines.first.tax_code } ]
      TudlaAccounting::Document.create!(organization: organization, kind: document.sales? ? "sales_credit" : "supplier_credit", contact: document.contact,
                                        credited_document: document, issued_on: [ document.issued_on + 7, last_day ].min, lines_attributes: credit_lines).approve!
      next
    end

    owed = document.total.cents
    paid = index % 10 == 6 ? owed / 2 : owed
    extra = (index % 50).zero? ? 10_00 : 0
    paid_on = [ document.issued_on + rand(0..40), last_day ].min
    payment = TudlaAccounting::Payment.record!(organization: organization, kind: document.sales? ? "received" : "paid", contact: document.contact, account: banks.first,
                                               paid_on: paid_on, amount_cents: paid + extra, applications: [ { document: document, amount_cents: paid } ])
    if extra.positive?
      TudlaAccounting::Payment.record!(organization: organization, kind: document.sales? ? "refund" : "supplier_refund", contact: document.contact, account: banks.first,
                                       paid_on: paid_on, amount_cents: extra, refund_of: payment)
    end
    payment
  end
end
puts format("  details: %d, balances: %d, documents: %d, payments: %d", TudlaAccounting::Detail.where(organization: organization).count,
            TudlaAccounting::Balance.where(organization: organization).count, TudlaAccounting::Document.where(organization: organization).count,
            TudlaAccounting::Payment.where(organization: organization).count)

year = years.last
months = year.children.order(:from_date).to_a
march = months[2]
bank = banks.first
puts "\nServices"
measure("trial balance (March)") { TudlaAccounting::Reports::TrialBalance.new(organization, march).rows }
measure("balance sheet (March)") { TudlaAccounting::Reports::BalanceSheet.new(organization, march).then { |r| r.respond_to?(:sections) ? r.sections : r } }
measure("profit and loss (year)") { TudlaAccounting::Reports::ProfitAndLoss.new(organization, year).then { |r| r.respond_to?(:sections) ? r.sections : r } }
measure("general ledger (March)") { TudlaAccounting::Reports::GeneralLedger.new(organization, from: march, thru: march).accounts }
measure("general ledger (year)") { TudlaAccounting::Reports::GeneralLedger.new(organization, from: months.first, thru: months.last).accounts }
measure("cash flow (year)") { TudlaAccounting::Reports::CashFlow.new(organization, from: months.first, thru: months.last, cash_accounts: [ accounts["1010"] ]).then { |r| [ r.sections, r.reconciles? ] } }
measure("tax summary (year)") { TudlaAccounting::TaxReport.call(organization, from: year.from_date, thru: year.thru_date) }
measure("profit and loss by department (year)") { TudlaAccounting::DimensionReport.call(organization, department, from: year.from_date, thru: year.thru_date) }
measure("receivables aging") { TudlaAccounting::AgingReportGenerator.call(organization: organization, report_type: :receivable, as_of_date: Date.new(2026, 6, 30)) }
busiest = customers.max_by { |customer| documents.count { |document| document.contact_id == customer.id } }
measure("statement (busiest customer, year)") do
  TudlaAccounting::PartyStatement.call(organization: organization, type: :receivable, party: busiest, from: year.from_date.to_date, thru: year.thru_date.to_date).then { |s| [ s.lines, s.closing, s.aging ] }
end
measure("statements to send (customers, March)") { TudlaAccounting::PartyStatement.to_send(organization, type: :receivable, from: march.from_date.to_date, thru: march.thru_date.to_date, open_items: false) }
measure("bills due (pay run)") { TudlaAccounting::PayRun.due(organization, currency: organization.currency) }
TudlaAccounting.configuration.reminder_days = [ 7, 14, 30 ]
measure("reminders due") { TudlaAccounting::ReminderRunner.due(organization: organization) }
TudlaAccounting::RecurringInvoice.create!(organization: organization, name: "Retainer", contact: busiest, frequency: "monthly", day_of_month: 1, starts_on: year.from_date.to_date,
                                          issue: "approve", lines_attributes: document_lines.call(busiest, false))
measure("recurring invoices (a year, approved)") { TudlaAccounting::RecurringInvoiceRunner.call(organization: organization, as_of: year.thru_date.to_date) }
budget = measure("budget from last year's actuals") do
  TudlaAccounting::Budget.create!(organization: organization, period: year, name: "Plan", main: true).tap { |plan| plan.fill_from_actuals!(years.first, percent: 5) }
end
measure("bank summary (one account)") { TudlaAccounting::BankReconciler.new(bank).summary(as_of: Date.new(2026, 12, 31)) }
measure("bank suggestions (one account)") { TudlaAccounting::BankReconciler.new(bank).suggestions }
differences = measure("balance check (differences)") { TudlaAccounting::BalanceRebuilder.new(organization).differences.size }
puts "  !! #{differences} balances differ from the posted entries" unless differences.zero?
# What moving retained earnings costs: the assigner rebuilds the balances under the
# posting lock, in its own transaction. An entry posted meanwhile waits for it: how long is
# how long the organization's posting stops. Moved back afterwards, unmeasured.
waiting = build_entry.call(ENTRY_COUNT)
locked = Queue.new
move = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do
    ActiveRecord::Base.transaction do
      organization.class.lock.find(organization.id) # held through the assigner's rebuild, which takes it too
      locked << true
      moved = measure("move retained earnings (with rebuild)") { TudlaAccounting::AccountRoleAssigner.save(accounts["3100"], :retained_earnings) }
      puts "  !! #{accounts['3100'].errors.full_messages.to_sentence}" unless moved
    end
  end
end
locked.pop
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
waiting.post(waiting.transacted_at)
puts format("%-44s %9.3fs", "  an entry posted meanwhile, waiting", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
move.join
TudlaAccounting::AccountRoleAssigner.save(accounts["3900"].reload, :retained_earnings)
measure("full rebuild (Setup, rake), nothing to fix") { TudlaAccounting::BalanceRebuilder.new(organization).rebuild! }
first_month = years.first.children.order(:from_date).first
measure("close a month") { first_month.close! }

puts "\nPages"
ActionController::Base.allow_forgery_protection = false # this script signs in with a plain POST
app = ActionDispatch::Integration::Session.new(Rails.application)
app.host! "localhost"
app.post "/session", params: { organization_id: organization.id }
base = "/tudla_accounting"
{
  "dashboard" => "/", "accounts" => "/accounts", "account (bank, ledger)" => "/accounts/#{bank.id}?year_id=#{year.id}",
  "entries" => "/entries", "entry" => "/entries/#{entries.last.id}", "trial balance" => "/reports/trial_balance?period_id=#{march.id}",
  "balance sheet" => "/reports/balance_sheet?period_id=#{march.id}", "profit and loss" => "/reports/profit_and_loss?period_id=#{year.id}",
  "general ledger (March)" => "/reports/general_ledger?from_id=#{march.id}&thru_id=#{march.id}",
  "general ledger (year)" => "/reports/general_ledger?from_id=#{months.first.id}&thru_id=#{months.last.id}",
  "cash flow" => "/reports/cash_flow?cash_account_ids[]=#{accounts['1010'].id}&from_id=#{months.first.id}&thru_id=#{months.last.id}",
  "tax summary" => "/reports/tax?from_id=#{months.first.id}&thru_id=#{months.last.id}", "by department" => "/reports/by_dimension",
  "banking (account)" => "/banking/#{bank.id}", "periods (year)" => "/periods/#{year.id}", "activity" => "/activity",
  "balance check" => "/setup/balances",
  "sales" => "/sales", "purchases" => "/purchases", "sales (overdue)" => "/sales?status=overdue", "invoice" => "/documents/#{documents.first.id}",
  "payments received" => "/sales/payments", "payments made" => "/purchases/payments", "payment" => "/payments/#{payments.first.id}",
  "new payment (busiest customer)" => "/payments/new?kind=received&contact_id=#{busiest.id}",
  "contacts" => "/contacts", "contact (busiest customer)" => "/contacts/#{busiest.id}", "receivables aging" => "/reports/receivables",
  "statement (busiest customer, year)" => "/reports/statement?type=receivable&party=#{TudlaAccounting::PartyStatement.key(busiest)}&from=#{year.from_date.to_date}&thru=#{year.thru_date.to_date}",
  "statements (customers, March)" => "/reports/statements?type=receivable&from=#{march.from_date.to_date}&thru=#{march.thru_date.to_date}",
  "pay run" => "/pay_run/new?due_by=#{year.thru_date.to_date}", "reminders due" => "/sales/reminders", "recurring invoices" => "/recurring_invoices",
  "budgets" => "/budgets", "budget" => "/budgets/#{budget.id}", "budget (edit)" => "/budgets/#{budget.id}/edit",
  "profit and loss vs budget" => "/reports/profit_and_loss?period_id=#{year.id}&compare=budget", "bank rules" => "/bank_rules"
}.each do |label, path|
  status = measure("GET #{label}") { app.get(base + path) }
  puts "  !! status #{status}" unless status == 200
end

if ENV["KEEP"]
  puts "\nKept #{organization.name} (##{organization.id})."
else
  # The integration session leaves Rails' execution context cleared; run inside the executor.
  Rails.application.executor.wrap { measure("delete the books") { purge(organization) } }
end
