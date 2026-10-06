# TudlaAccounting

A double-entry general ledger for Rails apps, packaged as a mountable **Rails 8.1 engine**. Add it to a host app to get a chart of accounts, balanced journal entries, and account balances that roll up through account and period hierarchies. It can also track receivables and payables, including in foreign currencies, and supports multiple organizations.

## What it does

### Chart of accounts
`TudlaAccounting::Account` belongs to an organization and has a `code`, a `name`, and a category: `asset`, `liability`, `equity`, `income` or `expense`. Accounts form a tree, e.g. *1100 Accounts Receivable > 1105 AR – EUR customers*. A child must share its parent's category. An account can name a **contra account**, which flips its normal side, e.g. accumulated depreciation against an asset.

### Accounting periods
`TudlaAccounting::Period` is a date range, and periods also form a tree: a year, then quarters, then months. `TudlaAccounting::PeriodCreator.call(organization, 2026)` builds a financial year and its twelve months in the configured time zone. Each period runs from the start of its first day to the end of its last. Pass a start month and day for a fiscal year, e.g. `PeriodCreator.call(org, 2026, 7, 1)`. `Period.ancestry_check(root)` checks that every period's children exactly cover it, with no gaps or overlaps.

### Journal entries
A `TudlaAccounting::Entry` is made up of `Detail` lines. Each line is a debit or credit of an amount to one account. An entry is only valid if:
- debits equal credits
- it has at least one debit and one credit
- all lines are in one currency

An entry can point at a `source` record in the host app, such as the invoice it came from, and a `related` entry, such as the invoice a payment settles. A line can carry a `ForeignExchange` record holding the foreign-currency amount and rate.

`Entry.create_from_ruby_hash` builds an entry from plain data. You give account codes and **signed** amounts, and it works out whether each line is a debit or credit from the account's normal side. Positive increases the account; negative decreases it.

### Posting and balances
`entry.post(posted_at)` posts every line to the period that contains `posted_at`, then stamps the entry. The whole post is one transaction: if any line fails, nothing is posted. Posting an entry twice raises `ArgumentError`. Posts lock the organization's row while they run, so concurrent posts for the same organization take turns instead of overwriting each other's balance updates; other organizations aren't blocked. Each account has one `TudlaAccounting::Balance` per period, holding starting, current and ending amounts. Posting:
- adds the amount to the balance of the deepest period containing `posted_at`, e.g. the month
- rolls it up into every parent period (quarter, year) and every parent account
- carries it forward into the starting amount of every later period, so back-dated entries keep later balances correct

**Year end.** Each top-level period is a financial year, and balances carry across years automatically, with no closing step:
- asset, liability and equity accounts open each year with their closing balance from the year before;
- income and expense accounts start each year at zero;
- the previous year's net profit (income less expenses) is added to the retained earnings account set in `retained_earnings_account_code`, and to the accounts above it.

Back-dated entries into an earlier year follow the same rules, so later years stay correct whatever order entries are posted in. `Balance.net_profit(organization, year)` returns a year's profit. Without `retained_earnings_account_code`, income and expenses still restart each year, but the profit isn't carried, so later years' balance sheets won't balance.

**Checking and rebuilding balances.** Balances are a running total kept by posting; the posted entries and the first year's opening balances are the record. `TudlaAccounting::BalanceRebuilder.new(organization).differences` works every balance out again from those, independently of the posting code, and lists any stored figure that differs (or a balance with activity that is missing). `rebuild!` rewrites the stored balances to match, under the same organization lock as posting, and never touches entries. From the command line:

```bash
bin/rails tudla_accounting:balances:check     # lists differences; exits 1 if there are any
bin/rails tudla_accounting:balances:rebuild   # ORGANIZATION=Organization:42 limits either task to one organization
```

### Database integrity
The engine's migrations add unique keys (one balance per account and period, account codes per organization, one carrying amount per line, one exchange rate per currency pair and day) and checks (positive line amounts, known tallies, categories and carrying-amount types). On PostgreSQL, triggers also refuse any change to a posted entry or its lines, or their deletion, from anywhere (a console, a job, raw SQL): correct posted entries by reversing them. Touching `updated_at` is allowed. Triggers likewise refuse posting into a closed period and any change to audit events. Data maintenance that really must change posted rows can run inside `TudlaAccounting::DatabaseProtection.allowing_posted_changes { ... }`, which lifts the protection for that block's transaction only.

Triggers can't be stored in `db/schema.rb`, so the engine reinstalls them after `db:schema:load`; run `bin/rails tudla_accounting:protect_posted_entries` if a database was built some other way.

### Closing periods
`period.close!` closes a month, or a year with all its months. Nothing more can be posted into a closed period: posting, reversing into it, revaluation entries and changes to opening balances in it are refused (and on PostgreSQL a trigger refuses it from anywhere). Periods close in order, each after the earlier ones, so later postings can never move a closed period's balances. `period.reopen!(reason: "...")` reopens the most recently closed period (a year before its months); the reason is kept in the audit trail. `close_blocker` and `reopen_blocker` say why either would be refused.

### Audit trail
Each change to the books records a `TudlaAccounting::AuditEvent`: entries posted, reversed and deleted as drafts; accounts added, changed and deleted; years created and deleted; periods closed and reopened (with the reason); opening balances saved; and balance rebuilds. Each event keeps who acted, the subject, any details, and labels for both, so it still reads after they are gone. Events can't be changed or deleted (a trigger on PostgreSQL).

Who acted comes from `TudlaAccounting::Current.actor`: the engine's pages set it from the `current_actor` setting, and other code can set it around its work with `TudlaAccounting::Current.set(actor: user) { ... }`. The actor can be a record (labelled by its `name` or `email`) or a plain string; events without one show as "System".

### Tax
`TudlaAccounting::TaxCode` records each tax lines can be taxed under: a code, a rate, whether it is on **sales** (tax collected) or **purchases** (tax paid), and the account the tax is posted to (a zero-rate code, such as GST-free, needs none but is still reported). Codes are managed under Setup → Tax codes; once lines are taxed under a code it can be made inactive but not deleted or switched between sales and purchases.

In `Entry.create_from_ruby_hash`, a line with `tax_code: "GST"` is taxed: its amount excludes the tax, and a line for the tax is added on the code's account, on the same side, so the other lines must include it (e.g. receivable 110, sales 100 with GST). With `tax_inclusive: true` (on the line or the whole hash) the amount includes the tax and is split instead, leaving the totals unchanged. Taxed lines and tax lines are tagged with the code (`tax_role` base or tax), and reversals keep the tags. Foreign-currency lines can't be taxed yet.

`TaxReport.call(organization, from:, thru:)` (Reports → Tax summary) totals, per code, the amounts taxed and the tax for lines posted in that time: sales codes count credits up, purchases codes debits, so credit notes and reversals reduce their own side. `net_tax` is tax on sales less tax on purchases: owed when positive, a refund when negative.

### Receivables and payables (carrying amounts)
After posting, `CarryingAmountProcessor` keeps track of what's still owed. Posting an entry whose source is an invoice or bill opens a `CarryingAmount` on its receivable or payable line, with a due date and any foreign-currency amount. Posting a payment, disbursement or credit note opens a **credit** for the customer or supplier: a carrying amount on its line with a negative amount. If money moves through a bank account held in another currency (`BankAccountBalance`), that balance is updated in its own currency.

Credits are applied to what is owed through **allocations** (`TudlaAccounting::Allocation`):
- A payment or credit note that names an invoice or bill as `related` is applied to it automatically, up to what is still owed. Anything over stays as the customer's or supplier's credit, so an invoice never goes below zero.
- `Allocator.allocate!(payment, invoice)` applies a credit to any open invoice or bill of the same party: as much as both allow, or `amount_cents:` (or `other_currency_cents:` for a foreign amount). `Allocator.allocate_oldest_first!(payment)` spreads it over the party's open items, earliest due first, and `Allocator.open_charges(payment)` lists them.
- `Allocator.unallocate!(allocation, at:)` takes one off again without reversing the payment. Reversing a payment or credit note takes it off everything it was applied to; an invoice or bill can be reversed once nothing is applied to it.
- A **refund** pays a credit back: cash to a customer (Dr receivable, Cr bank), or from a supplier. It opens a charge like an invoice and uses up the credit it names as `related`; one paid in a foreign currency at another rate books the realized difference, and a refund without `related` waits to be matched like any charge. Reversing a refund gives the credit back.
- Allocations are dated, so `CarryingAmount#outstanding(as_of:)` and the aging report show what was owed on any day. Dates in a closed period are refused, and each allocation is in the audit trail.

The migration that adds allocations converts payments posted before them: each gets its credit, applied to its related invoice or bill as far as that was owed (`AllocationBackfill`, safe to run again).

This is **off until configured**. The host app chooses which of its models count as invoices, bills, payments and disbursements, and which accounts are receivables and payables. See [Configuration](#configuration).

### Setting up the books
- **`AccountsCreator.call(nested_accounts, organization)`** creates a chart of accounts from nested hashes (`code`, `name`, `category`, optional `currency` and `contra_account`, `children`), all or nothing.
- **`StartingBalanceCreator.call(organization, date, nodes, currency)`** sets opening balances in the first period at every level, i.e. the first month of the first year; later years carry forward automatically. Each parent's amount must equal the sum of its children's.
- **`CsvLoader` / `XlsxLoader.call(organization, file, date)`** do both from a spreadsheet with the columns `Account Code`, `Account Name`, `Account Type`, `Contra Code`, `Starting Balance`, `Parent Account Code`. See `spec/fixtures/files/coa_saas_services.csv` for an example.

- **`CarryingAmountsCreator.call(organization:, csv_file:, date_prior:, sales_account_code:, purchase_account_code:, source: nil)`** imports the invoices and bills still open at the cut-over, so the aging report and later payments work. The CSV columns are `particulars`, `amount`, `type`, `due_date`, and for foreign-currency rows `other_currency`, `other_currency_amount`, `transaction_rate` and `conversion_date`; see `spec/fixtures/files/carrying_amounts.csv`. Each row becomes an entry dated `date_prior`, marked posted but not changing balances, since the opening balances already include these amounts. Foreign-currency rows go to a currency sub-account such as `1100-EUR`. `source` can turn each row into a host record. The whole file imports all or nothing.

Opening balances are signed the natural way for each category, so a contra account such as accumulated depreciation is entered as a negative amount. The engine stores it on the contra account's own side, so later posting adds to it. Reloading over existing accounts or balances needs `overwrite_mode` (the last argument); any later balances that already exist move by the same amount.

### Entries from host-app records
Register how each host model turns into an entry, then create entries from records:

```ruby
# config/initializers/tudla_accounting.rb
Rails.application.config.to_prepare do
  TudlaAccounting.register_entry_source("Invoice", ->(invoice) {
    {
      organization_type: "Organization", organization_id: invoice.organization_id,
      particulars: "Invoice ##{invoice.number}",
      transacted_at: invoice.issued_at.iso8601,
      details: [
        { account_code: "1100", amount: "USD #{invoice.total}" },
        { account_code: "4000", amount: "USD #{invoice.total}" }
      ]
    } # return nil to skip
  })
end

entry = TudlaAccounting.create_entry_from_source!(invoice) # linked back via source_type/source_id
TudlaAccounting::EntryPostingJob.perform_later(entry.id)
```

`EntryPostingJob` posts the entry into the period of its `transacted_at`, on the `entry_posting` queue. With Solid Queue, only one posting job per organization runs at a time. A failed job is logged and discarded, not retried, and the entry stays unposted.

### Aging report
`AgingReportGenerator.call(organization:, report_type: :receivable, as_of_date:)` (or `:payable`) groups open amounts by related party and buckets them by days past due: current, 1–30, 31–60, 61–90 and over 90. It returns `summary` and `details` per party, plus `totals`, in the organization's currency. A past `as_of_date` shows what was owed on that day: later invoices are left out and later payments are added back. Credits not yet applied are listed as lines of their own with a negative amount, in the current bucket, so each party's total is what it owes net.

### Foreign exchange
- **`ForexRateRetriever.call(from:, to:, date:)`** returns how many `to` one `from` was worth on a date. Rates are cached in `ForexRate`, and missing ones come from `forex_rate_provider`.
- **`RbaForexRateProvider`** reads the Reserve Bank of Australia's published rates. It needs the `spreadsheet` gem in the host app and network access. A weekend or holiday uses the latest earlier business day.
- **`ForexGainOrLossCalculator`** gives the gain or loss on a foreign amount of a receivable or payable between its booked rate and a date's rate.
- **Settlement at a different rate.** When a foreign-currency payment or credit is applied to a foreign-currency invoice or bill, its carrying amount goes down by the book value of the foreign amount, at the rate it was booked at. The difference from the credit's own value for that foreign amount is posted as a realized exchange gain or loss against `realized_fx_gain_account_code`, dated with the allocation (and reversed if the allocation is taken off). Each part payment books its own share, and the final one books what remains, so the receivable or payable ends at zero. An overpayment books a gain or loss only on what was owed, and leaves the extra as a credit in the foreign currency. Without that setting, the carrying amount is still correct, but the difference stays on the receivable or payable account and a warning is logged.
- **`RevaluationEntryGenerator.call(organization, period_end, next_period_start)`** revalues open foreign-currency receivables and payables at the period-end rate. It posts the unrealized gain or loss against `unrealized_fx_gain_account_code`, then posts a reversal on the next period's start, so the later settlement isn't double-counted. Running it twice for the same date does nothing more.

### Multi-tenancy
Accounts, periods, entries, lines and balances all belong to a polymorphic `organization`, provided by the host app. The organization must respond to `currency`, which is the currency its books are kept in.

## Web pages

Mounted at `/accounting` by the install generator (see [Integration](#integration-into-a-host-application)), the engine has pages for the organization returned by `current_organization`:

- **Dashboard:** profit this year, what is owed each way, draft entries, recent entries, and a getting-started checklist.
- **Accounts:** the chart of accounts as a tree with closing balances. Each account page shows monthly balances and a ledger with running balances. You can create, edit and delete unused accounts.
- **Entries:** search and filter entries, write drafts with a line editor that keeps live debit/credit totals, post them, and reverse posted entries. A posted payment or credit note shows what it was applied to and what is left, with forms to apply it to the party's open invoices or bills (or oldest first) and to take an allocation off; an invoice or bill shows what was applied to it. Reversing a payment takes it off what it settled and reverses its realized exchange difference. An invoice or bill can be reversed once nothing is applied to it, which closes its receivable or payable.
- **Reports:** balance sheet, profit and loss, trial balance, receivables and payables aging, and a tax summary for a run of months.
- **Periods:** create calendar or fiscal years, see each year's months, and close or reopen them (reopening asks for a reason).
- **Setup:** upload a chart of accounts with opening balances (CSV or Excel), or enter or correct opening balances account by account, with live totals checking that they balance. Manage tax codes. Also import the receivables and payables open at the cut-over, and run the foreign exchange revaluation. A balance check compares the stored balances with the posted entries and can rebuild them.
- **Activity:** the audit trail, newest first, filterable by kind, linking to entries, accounts and years that still exist.

The pages use Tailwind CSS with the engine's own `tc-` component classes (no DaisyUI needed) and follow the host's light/dark theme. Their Stimulus controllers load through the engine's import map.

## Usage

```ruby
org = Organization.find(1) # your host model; must respond to #currency

# A calendar year of periods, and a few accounts
year = TudlaAccounting::PeriodCreator.call(org, 2026)
cash  = TudlaAccounting::Account.create!(organization: org, code: "1000", name: "Cash", category: :asset, currency: "USD")
ar    = TudlaAccounting::Account.create!(organization: org, code: "1100", name: "Accounts Receivable", category: :asset, currency: "USD")
sales = TudlaAccounting::Account.create!(organization: org, code: "4000", name: "Sales", category: :income, currency: "USD")

# Invoice: amounts are signed, positive increases the account
invoice = TudlaAccounting::Entry.create_from_ruby_hash(
  organization_type: "Organization", organization_id: org.id,
  particulars: "Invoice #42",
  transacted_at: "2026-03-10T09:00:00Z",
  details: [
    { account_code: "1100", amount: "USD 1100.00" }, # debit AR
    { account_code: "4000", amount: "USD 1100.00" }  # credit Sales
  ]
)
invoice.post(Time.zone.parse("2026-03-10 09:00"))

# Payment in April: AR goes down, cash goes up
payment = TudlaAccounting::Entry.create_from_ruby_hash(
  organization_type: "Organization", organization_id: org.id,
  particulars: "Payment for invoice #42",
  transacted_at: "2026-04-02T10:00:00Z",
  details: [
    { account_code: "1100", amount: "USD -1100.00" }, # credit AR
    { account_code: "1000", amount: "USD 1100.00" }   # debit Cash
  ]
)
payment.post(Time.zone.parse("2026-04-02 10:00"))

march, april = year.children.order(:from_date).to_a.values_at(2, 3)
TudlaAccounting::Balance.find_by(account: ar, period: march).ending_amount    # => 1100.00 USD
TudlaAccounting::Balance.find_by(account: ar, period: april).starting_amount  # => 1100.00 USD (carried forward)
TudlaAccounting::Balance.find_by(account: ar, period: april).ending_amount    # => 0.00 USD
TudlaAccounting::Balance.find_by(account: sales, period: year).current_amount # => 1100.00 USD (year to date)
TudlaAccounting::Balance.find_by(account: cash, period: year).ending_amount   # => 1100.00 USD
```

## Stack

- **Rails 8.1+** mountable engine with `isolate_namespace TudlaAccounting`
- **money-rails** for amounts and currencies, **ancestry** for the account and period trees
- **Solid Queue / Solid Cache / Solid Cable** for SQL-backed jobs, caching and Action Cable
- **Tailwind CSS v4** for engine views (no DaisyUI dependency) and **Importmap Rails**
- **RSpec**, **FactoryBot**, **SimpleCov** (100% line coverage), **Capybara**
- **RuboCop** with `rubocop-rails-omakase`
- A full dummy Rails app in `spec/dummy/` for running the engine

## Getting Started

```bash
docker compose up -d
docker compose exec rails bash -lc 'bin/setup'
docker compose exec rails bash -lc 'RAILS_ENV=test bundle exec rspec'
```

## Development Workflow

### Running Tests
```bash
docker compose exec rails bash -lc 'RAILS_ENV=test bundle exec rspec'                  # Run all specs
docker compose exec rails bash -lc 'RAILS_ENV=test bundle exec rspec spec/models/'     # Run specific directory
docker compose exec rails bash -lc 'RAILS_ENV=test bundle exec rspec --format doc'     # Verbose output
```

> **Note:** Always prefix `bundle exec rspec` with `RAILS_ENV=test`. The container has `RAILS_ENV=development` in its environment, which overrides the `||=` default in `rails_helper.rb`.

### Code Coverage
SimpleCov generates an HTML report in `coverage/` after each test run. Open `coverage/index.html` to view detailed metrics.

### Linting
```bash
docker compose exec rails bash -lc 'bundle exec rubocop'     # Check code style
docker compose exec rails bash -lc 'bundle exec rubocop -a'  # Auto-fix offenses
```

### Dummy App (Development Server)
```bash
docker compose exec rails bash -lc 'bin/setup'                                                    # First-time DB setup
docker compose exec -d rails bash -lc 'bin/dev'                                                   # Start dev server (background)
docker compose exec rails bash -lc "ps aux | grep -E 'foreman' | grep -v grep"                   # Check if running
docker compose exec rails bash -lc 'pkill -f foreman || true'                                     # Stop dev server
```

## Integration into a Host Application

```ruby
# Gemfile
gem "tudla_accounting", path: "../path/to/tudla_accounting"
```

Then:
```bash
bundle install
bin/rails generate tudla_accounting:install   # --mount-path=/books, --skip-migrations
bin/rails db:migrate
```

The generator writes `config/initializers/tudla_accounting.rb` with every setting, mounts the engine (at `/accounting` by default), copies the engine's migrations, and imports the engine's styles into `app/assets/tailwind/application.css` (with tailwindcss-rails). To do it by hand: `bin/rails tudla_accounting:install:migrations`, `mount TudlaAccounting::Engine => "/accounting"` in `config/routes.rb`, and `@import "../builds/tailwind/tudla_accounting";` in the Tailwind entry point.

### Hooks for the host app

- **Authorization.** `config.authorize = ->(controller, permission) { ... }` is asked before every page and action, with the permission it needs: `:read`, `:record` (drafts and accounts), `:post` (posting, reversing, applying payments) or `:administer` (periods and setup). A falsy answer gets a 403 page, and the pages hide the buttons for what isn't allowed. Without it, everyone who reaches the pages can do everything.
- **Who did it.** `config.current_actor` names the user on the audit trail; around background work, use `TudlaAccounting::Current.set(actor: user) { ... }`.
- **Events.** `TudlaAccounting.subscribe("entry.posted") { |event| ... }` calls the block with the `AuditEvent` after the change commits (never for one rolled back); with no action it receives every one. The actions are `TudlaAccounting::EVENTS`, also published as `ActiveSupport::Notifications` named `"<action>.tudla_accounting"`.
- **Idempotency.** `Entry.create_from_ruby_hash(..., idempotency_key: "stripe-ch_123")` returns the entry already created with that key for the organization instead of booking it twice, even when two processes race. `TudlaAccounting.create_entry_from_source!(record)` uses `"Type:id"` as the key unless the registered callable returns its own (or `idempotency_key: nil` for none).

### Configuration

Configure the engine in an initializer, e.g. `config/initializers/tudla_accounting.rb`:

```ruby
TudlaAccounting.configure do |config|
  # Web pages: engine controllers inherit from this host controller (its login and
  # helpers apply), and show the books of the organization this returns (403 if nil).
  config.parent_controller = "::ApplicationController"
  config.current_organization = ->(controller) { controller.current_organization }
  config.current_actor = ->(controller) { controller.current_user } # recorded on audit events (optional)

  config.base_currency = "USD"
  config.time_zone = "UTC"                # zone PeriodCreator builds periods in; plain Dates are read in it
  config.retained_earnings_account_code = "3900" # takes in each year's net profit at year end

  # Receivables and payables (carrying amounts). Off until configured: entries
  # still post normally, but no carrying amounts are tracked.
  config.receivable_account_code = "1100" # this account and every account beneath it
  config.payable_account_code = "2100"
  config.carrying_amount_sources = {      # entry source class => role
    "Invoice" => :receivable,             # opens a receivable
    "Bill" => :payable,                   # opens a payable
    "Payment" => :receipt,                # a customer's credit, applied to entry.related if set
    "Disbursement" => :disbursement,      # a credit with a supplier, applied to entry.related if set
    "CreditNote" => :credit_note,         # like a receipt, without cash
    "SupplierCredit" => :supplier_credit, # like a disbursement, without cash
    "Refund" => :refund,                  # pays a customer's credit (entry.related) back
    "SupplierRefund" => :supplier_refund  # a supplier pays a credit with them back
  }
  config.due_date_method = :due_date      # read from the source; blank if it doesn't respond
  config.related_party_method = :customer # who owes or is owed, read from the source; the organization if unset

  # Foreign exchange: where missing rates come from, and where revaluation gains/losses go
  config.forex_rate_provider = TudlaAccounting::RbaForexRateProvider.new # or any ->(from:, to:, date:) { rate }
  config.unrealized_fx_gain_account_code = "4900"
  config.realized_fx_gain_account_code = "4950"   # gains/losses when foreign invoices and bills are settled
end
```

## UI Development

### Dummy App
The dummy app (`spec/dummy/`) uses **Tailwind CSS v4** and **DaisyUI** for all UI work. Reference: https://daisyui.com/llms.txt

### Engine
Engine views use **Tailwind CSS v4 only** — no DaisyUI dependency. Engine styles must work standalone in any host app. They should be compatible with DaisyUI (no conflicts) but must not require it.

## Database Configuration Notes

The Solid gems require **multi-database configuration**. The dummy app uses separate databases for:
- `primary` - Main application data
- `queue` - Solid Queue tables
- `cache` - Solid Cache tables
- `cable` - Solid Cable tables

**Important:** Configure `connects_to` in environment files, not `database:` keys in `database.yml`, to avoid conflicts.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
