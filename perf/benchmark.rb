# Times posting and the engine's reports and pages on a large generated set of books.
#
#   bin/rails runner perf/benchmark.rb              # 2,000 entries over two years
#   ENTRIES=10000 KEEP=1 bin/rails runner perf/benchmark.rb
#
# Runs in its own organization ("Perf Co"), deleted afterwards unless KEEP=1. Prints the
# time and the number of SQL queries for each step.
ENTRY_COUNT = Integer(ENV.fetch("ENTRIES", "2000"))
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
    { code: "1100", name: "Receivables", category: "asset" }, { code: "1500", name: "Equipment", category: "asset" } ] },
  { code: "2000", name: "Liabilities", category: "liability", children: [
    { code: "2100", name: "Payables", category: "liability" }, { code: "2200", name: "GST", category: "liability" }, { code: "2500", name: "Loan", category: "liability" } ] },
  { code: "3000", name: "Equity", category: "equity", children: [ { code: "3100", name: "Capital", category: "equity" }, { code: "3900", name: "Retained earnings", category: "equity" } ] },
  { code: "4000", name: "Income", category: "income", children: (1..4).map { |i| { code: "40#{i}0", name: "Sales #{i}", category: "income" } } },
  { code: "6000", name: "Expenses", category: "expense", children: (1..9).map { |i| { code: "60#{i}0", name: "Expense #{i}", category: "expense" } } }
], organization)
accounts = TudlaAccounting::Account.where(organization: organization).index_by(&:code)
accounts["1500"].update!(cash_flow_activity: :investing)
accounts["2500"].update!(cash_flow_activity: :financing)
gst = TudlaAccounting::TaxCode.create!(organization: organization, code: "GST", name: "GST", rate: "0.1", kind: :sales, account: accounts["2200"])
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
puts format("  details: %d, balances: %d", TudlaAccounting::Detail.where(organization: organization).count, TudlaAccounting::Balance.where(organization: organization).count)

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
measure("bank summary (one account)") { TudlaAccounting::BankReconciler.new(bank).summary(as_of: Date.new(2026, 12, 31)) }
measure("bank suggestions (one account)") { TudlaAccounting::BankReconciler.new(bank).suggestions }
differences = measure("balance check (differences)") { TudlaAccounting::BalanceRebuilder.new(organization).differences.size }
puts "  !! #{differences} balances differ from the posted entries" unless differences.zero?

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
  "balance check" => "/setup/balances"
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
