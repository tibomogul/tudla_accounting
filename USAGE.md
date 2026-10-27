<!--
This guide is tested. spec/integration/usage_guide_spec.rb runs its ```ruby blocks in order as
one console session, picking them by the heading they're under, with Organization.find(1)
swapped for the spec's organization, and runs its `bin/rails tudla_accounting:*` lines as rake
tasks. spec/system/usage_guide_spec.rb follows the UI steps by the labels they name. Keep each
Ruby block runnable after the ones before it (write alternatives as comments), and update both
specs when a heading or a label changes.
-->

# Setting up the books

This guide takes an organization from nothing to books ready for day-to-day posting. Each step can be done in the engine's pages or from a Rails console (or `bin/rails runner`), and the steps go in this order:

1. [Install the engine](#1-install-the-engine) (once per host app)
2. [Create a financial year](#2-create-a-financial-year)
3. [Load the chart of accounts](#3-load-the-chart-of-accounts)
4. [Mark the accounts the books treat specially](#4-mark-the-accounts-the-books-treat-specially)
5. [Enter opening balances](#5-enter-opening-balances)
6. [Add tax codes and dimensions](#6-add-tax-codes-and-dimensions) (optional)
7. [Add customers and suppliers](#7-add-customers-and-suppliers) (optional)
8. [Import open receivables and payables](#8-import-open-receivables-and-payables) (optional)
9. [Check the books](#9-check-the-books)

Then, as the books run: [revaluing foreign currency](#revaluing-foreign-currency), [closing periods](#closing-periods) and [the next year](#the-next-year).

The pages are at the engine's mount path (`/accounting` by default), for the organization the `current_organization` setting returns. Setup pages need the `:administer` permission (see `config.authorize` in the [README](README.md#hooks-for-the-host-app)). The console examples assume:

```ruby
org = Organization.find(1) # your host model; it must respond to #currency
TudlaAccounting::Current.actor = "Setup script" # who the audit trail says did it (optional; "System" otherwise)
```

There are no rake tasks for loading books, only for checking them (step 9) and installing. A one-off script works for anything below:

```bash
bin/rails runner 'org = Organization.find(1); TudlaAccounting::PeriodCreator.call(org, 2026)'
```

---

## 1. Install the engine

```bash
bundle add tudla_accounting --github tibomogul/tudla_accounting
bin/rails generate tudla_accounting:install   # --mount-path=/books, --skip-migrations
bin/rails db:migrate
```

The generator writes `config/initializers/tudla_accounting.rb`, mounts the engine, copies its migrations and imports its styles. At least set:

```ruby
TudlaAccounting.configure do |config|
  config.parent_controller = "::ApplicationController"
  config.current_organization = ->(controller) { controller.send(:current_organization) }
  config.base_currency = "USD"
  config.time_zone = "Australia/Sydney" # financial years and months are built in this zone
end
```

The rest of the settings (receivables and payables, cash accounts, exchange rates, authorization) are described in the [README](README.md#configuration).

To send invoices, statements and payment receipts to customers and suppliers, also set:

- `document_header`: who printed documents are from, such as the organization's name and address;
- `document_mail_from` and `document_mail_reply_to`: the addresses emails go from and are answered to. Emails go through the host's own ActionMailer setup, in the background, so the host's Active Job backend must run jobs;
- `reminder_days`: the days after the due date to remind customers of overdue invoices, such as `[7, 14, 30]`. Without it, no reminders go out.

PDFs need the `ferrum` gem in the host's bundle and Chrome or Chromium on the server; without them, documents can only be printed from the browser. Attachments, such as a supplier's bill on its record, need Active Storage (`bin/rails active_storage:install`). The [README](README.md#pdfs) has the details of each.

If the database was built without Rails' schema tasks, install the triggers that protect posted entries:

```bash
bin/rails tudla_accounting:protect_posted_entries
```

## 2. Create a financial year

Entries post into periods, and opening balances go into the first month of the first year, so a year comes first.

**In the UI:** Periods → New financial year. Pick the year, the month it starts in and the day (1–28): a calendar year starts in January on day 1, a July–June year in July.

**In the console:**

```ruby
year = TudlaAccounting::PeriodCreator.call(org, 2026)  # the calendar year 2026
year.children.order(:from_date).pluck(:from_date)      # its twelve months
# A July–June year instead: TudlaAccounting::PeriodCreator.call(org, 2026, 7, 1), for 1 July 2026 – 30 June 2027
```

It returns the year, or `nil` (with the reason in the log) if a period fails validation, and raises `TudlaAccounting::PeriodInvalid` for a year that overlaps another. Create the next year whenever you like; balances carry into it automatically.

## 3. Load the chart of accounts

Choose one of three ways: upload a spreadsheet, create the accounts from Ruby, or add them one at a time.

### From a spreadsheet (CSV or Excel)

The file has these columns:

| Column | |
|---|---|
| `Account Code` | Unique within the organization |
| `Account Name` | |
| `Account Type` | Asset(s), Liability/Liabilities, Equity, Income, Revenue or Expense(s) |
| `Contra Code` | For a contra account, the code of the account it offsets |
| `Starting Balance` | The opening balance, signed the natural way for the category: contra accounts are negative |
| `Parent Account Code` | The parent's code; it must be in the same file |
| `Role` | Optional: `receivable`, `payable`, `retained_earnings`, `unrealized_fx_gain` or `realized_fx_gain` (see step 4) |

Each parent's starting balance must equal the sum of its children's. See `spec/fixtures/files/coa_saas_services.csv` for a complete example, which leaves the roles to step 4. These are its first rows, with a `Role` column added to mark accounts receivable:

```csv
Account Code,Account Name,Account Type,Contra Code,Starting Balance,Parent Account Code,Role
1000,Assets,Asset,,94000,,
1010,Current Assets,Asset,,64000,1000,
1011,Operating Cash Account,Asset,,25000,1010,
1012,Savings Account,Asset,,10000,1010,
1020,Accounts Receivable,Asset,,20000,1010,receivable
1025,Allowance for Doubtful Accounts,Asset,1020,-1000,1010,
```

**In the UI:** Setup → Chart of accounts and opening balances. Choose the file and the date of the opening balances (the start of the first year), and tick "Replace accounts and opening balances that already exist" to load over earlier accounts.

**In the console:**

```ruby
TudlaAccounting::CsvLoader.call(org, "chart.csv", Date.new(2026, 1, 1))          # from a CSV file
TudlaAccounting::XlsxLoader.call(org, "chart.xlsx", Date.new(2026, 1, 1), true)  # from Excel, replacing what's there (overwrite mode)
```

The whole file loads or nothing does. Problems raise `ArgumentError` naming the row (an unknown type or role, a duplicate code, a role given to more than one account, a missing parent).

### From Ruby

`AccountsCreator` takes nested hashes and creates them all or none. It sets no balances; enter those in step 5.

```ruby
TudlaAccounting::AccountsCreator.call([
  { code: "1000", name: "Assets", category: "asset", children: [
    { code: "1010", name: "Cash at bank", category: "asset" },
    { code: "1100", name: "Accounts receivable", category: "asset", role: "receivable" },
    { code: "1500", name: "Equipment", category: "asset" },
    { code: "1510", name: "Accumulated depreciation", category: "asset", contra_account: "1500" }
  ] },
  { code: "2000", name: "Liabilities", category: "liability", children: [
    { code: "2100", name: "Accounts payable", category: "liability", role: "payable" },
    { code: "2200", name: "GST", category: "liability" }
  ] },
  { code: "3000", name: "Equity", category: "equity", children: [
    { code: "3100", name: "Owner's capital", category: "equity" },
    { code: "3900", name: "Retained earnings", category: "equity", role: "retained_earnings" }
  ] },
  { code: "4000", name: "Income", category: "income", children: [
    { code: "4010", name: "Sales", category: "income" },
    { code: "4900", name: "Realized exchange gains and losses", category: "income", role: "realized_fx_gain" },
    { code: "4910", name: "Unrealized exchange gains and losses", category: "income", role: "unrealized_fx_gain" }
  ] },
  { code: "6000", name: "Expenses", category: "expense" }
], org)
```

`currency` defaults to the organization's. `contra_account` names the code of the account it offsets. Pass a parent account's id as the third argument to add accounts beneath an existing one:

```ruby
TudlaAccounting::AccountsCreator.call([ { code: "6010", name: "Rent", category: "expense" } ], org, TudlaAccounting::Account.find_by(organization: org, code: "6000").id)
```

### One at a time

**In the UI:** Accounts → New account, or "Add sub-account" on an account's page. The form sets the code, name, category, currency, parent, contra account, cash flow activity and role.

**In the console:**

```ruby
TudlaAccounting::Account.create!(organization: org, code: "6020", name: "Software", category: :expense, parent: TudlaAccounting::Account.find_by(organization: org, code: "6000"))
```

A child must have its parent's category. Category, parent and contra account are fixed once the account has postings. Only an account with no postings, sub-accounts or contra accounts can be deleted.

## 4. Mark the accounts the books treat specially

The engine finds certain accounts by their role, never by their code. Each organization marks at most one account for each role:

| Role | Category | Without it |
|---|---|---|
| `receivable` | asset | No receivables are tracked: no open invoices, aging or allocations |
| `payable` | liability | No payables are tracked |
| `retained_earnings` | equity | Each year's profit isn't carried, so later balance sheets don't balance |
| `unrealized_fx_gain` | income or expense | Revaluation raises when there are foreign-currency items to revalue |
| `realized_fx_gain` | income or expense | Exchange differences on settlement stay on the receivable or payable account, and a warning is logged |

Receivables and payables cover the marked account and every account beneath it, such as `1100-EUR`.

The dashboard warns, and `balances:check` prints a warning, while no account is marked retained earnings, receivable or payable (when `carrying_amount_sources` records that side), or either exchange role once an account is held in another currency.

**In the UI:**

- **Setting a role:** pick it under Role in the account form. If another account holds the role, the role moves to this one. Only those with the `:administer` permission can change a role; others see it greyed out.
- **Seeing the roles:** the chart of accounts shows each role as a badge, and the Setup page shows which accounts hold them, with "none marked" where none does.

**In the console**, use `AccountRoleAssigner`, the only way a role changes. It moves a role from the account holding it, and has the balances rebuilt when retained earnings changes on books that already have some:

```ruby
retained = TudlaAccounting::Account.find_by(organization: org, code: "3900")
TudlaAccounting::AccountRoleAssigner.save(retained, :retained_earnings)  # => true, or false with retained.errors
TudlaAccounting::Account.for_role(org, :retained_earnings)               # => retained (nil when no account has the role)
# TudlaAccounting::AccountRoleAssigner.save(retained, nil) takes the role off again
```

Receivables and payables are marked the same way:

```ruby
receivables = TudlaAccounting::Account.find_by(organization: org, code: "1100")
TudlaAccounting::AccountRoleAssigner.save(receivables, :receivable)
```

The rules:

- Each role needs an account of a suitable category.
- Receivables and payables stay on an account once it, or an account beneath it, has posted lines, because its open items would otherwise be left behind. Opening balances and drafts don't count.
- Receivables and payables can't be given to an account that already has posted lines, on it or beneath it: those lines opened nothing owed. Mark the account before posting to it. Opening balances and drafts don't count.
- A plain `account.update(role: ...)` is refused: roles change only through `AccountRoleAssigner` (`save!` raises instead of returning false).
- Changing retained earnings has the balances rebuilt when the organization already has some.
- Retained earnings can't change while a period after the first year is closed: each later year carries the earlier years' profit into it, and a closed period's balances stay as they were closed. Reopen those periods first (latest first; see [Closing periods](#closing-periods)), then close them again.

Marking retained earnings late is fine. If years were posted before any account was marked (a client taken on mid-stream), marking it has the balances rebuilt so every earlier year's profit lands in the account.

The rebuild runs as part of the change, in the same transaction, so the balances are never left behind: if it fails, the role doesn't change either. It rewrites every balance that differs from the posted entries, and the activity log names the accounts it corrected. Several changes made with `AccountRoleAssigner.batch(org) { |assigner| ... }` cost one rebuild between them, and are all or nothing: if one is refused, none is made and `batch` returns false.

**How long it takes.** The rebuild reads every posted line of the organization while holding its posting lock, so the change, and any posting for that organization (and only that one), waits until it finishes. `perf/benchmark.rb` measures it, on two years of books with about 30 accounts:

| Posted entries (lines) | Rebuild | An entry posted meanwhile waits |
|---|---|---|
| 2,000 (5,000) | 0.12 s | 0.15 s |
| 20,000 (50,000) | 0.51 s | 0.54 s |

The time grows with the number of posted lines, about 10 µs a line, with the same 13 queries at any size. On that trend a million lines would take around ten seconds, and the account form would wait as long. Books with many more accounts or years cost more, so run `ENTRIES=... bin/rails runner perf/benchmark.rb` sized like your largest organization before relying on these figures. For very large books, change retained earnings outside working hours.

## 5. Enter opening balances

Skip this step if the spreadsheet in step 3 had starting balances.

Opening balances go at the start of the first financial year. Later years take theirs from the year before.

**In the UI:** Setup → Enter opening balances.

- **Entering:** type one amount for each account without sub-accounts. Parents add up their children.
- **Contra accounts:** enter them as positive amounts; they reduce their category.
- **Checking:** live totals show whether debits equal credits.
- **Saving:** saving replaces any opening balances already there. You land on the balance sheet for the first month.

**In the console**, use `StartingBalanceCreator`. Its nodes are nested like the account tree, with amounts in cents:

- Amounts are signed the natural way for the category, so a contra account is negative.
- Each parent's amount must equal the sum of its children's.
- The last argument is overwrite mode, which replaces opening balances already there.

```ruby
account = ->(code) { TudlaAccounting::Account.find_by!(organization: org, code: code).id }

TudlaAccounting::StartingBalanceCreator.call(org, Date.new(2026, 1, 1), [
  { account_id: account["1000"], amount_cents: 30_000_00, children: [
    { account_id: account["1010"], amount_cents: 25_000_00 },
    { account_id: account["1500"], amount_cents: 6_000_00 },
    { account_id: account["1510"], amount_cents: -1_000_00 } # accumulated depreciation
  ] },
  { account_id: account["3000"], amount_cents: 30_000_00, children: [
    { account_id: account["3100"], amount_cents: 30_000_00 }
  ] }
], org.currency)
```

The date must fall in the first period at every level, that is, the first month of the first year. Saving opening balances is recorded in the audit trail.

## 6. Add tax codes and dimensions

**Tax codes** are the taxes lines can be taxed under. Each has:

- a code and a name;
- a rate: a percentage in the form (`10`), a fraction in the console (`0.1`);
- whether it applies to **sales** (tax collected) or **purchases** (tax paid);
- the account the tax posts to. A zero-rate code, such as GST-free, needs no account.

**In the UI:** Setup → Manage tax codes.

**In the console:**

```ruby
gst = TudlaAccounting::Account.find_by(organization: org, code: "2200")
TudlaAccounting::TaxCode.create!(organization: org, code: "GST", name: "GST on sales", rate: "0.1", kind: :sales, account: gst)
TudlaAccounting::TaxCode.create!(organization: org, code: "GST-P", name: "GST on purchases", rate: "0.1", kind: :purchases, account: gst)
TudlaAccounting::TaxCode.create!(organization: org, code: "FRE", name: "GST-free", rate: "0", kind: :sales)
```

Once lines are taxed under a code, it can be made inactive (`active: false`), but it can't be deleted or switched between sales and purchases.

**Dimensions**, such as department, project or location, tag entry lines for profit and loss by each. Each line can carry at most one value of each dimension.

**In the UI:** Setup → Manage dimensions, then add the values.

**In the console:**

```ruby
department = TudlaAccounting::Dimension.create!(organization: org, code: "DEPT", name: "Department")
%w[SALES ENG OPS].each { |code| department.dimension_values.create!(code: code, name: code.capitalize) }
```

## 7. Add customers and suppliers

Contacts are the customers and suppliers that invoices and bills are to or from. Each has a kind (`customer`, `supplier` or `both`), an email address for sending them documents, and optionally payment terms in days and a default account and tax code. New documents for the contact start from these.

Contacts can be imported from a spreadsheet (CSV or Excel) with these columns. Only `Name` is needed:

```csv
Name,Kind,Email,Phone,Address,Tax number,Payment terms (days),Default account,Default tax code,Notes
Northwind Traders,customer,accounts@northwind.test,02 9000 1234,"1 Harbour St, Sydney",51 824 753 556,14,,GST,
Globex,customer,payables@globex.test,,,,30,,GST,
Initech Supplies,supplier,billing@initech.test,,,,30,,,Office supplies
```

- `Default account` and `Default tax code` are codes, which must already exist.
- A row whose name is already a contact updates that contact, ignoring case.
- The whole file imports or nothing does.
- See `spec/fixtures/files/contacts.csv` for this example.

**In the UI:** Contacts → Import contacts (CSV or Excel), or New contact to add one at a time. The Contacts page's Download CSV writes the same columns, so a list can be downloaded, changed and imported again.

**In the console:**

```ruby
TudlaAccounting::ContactImporter.call(org, "contacts.csv", ".csv") # => { added: 3, updated: 0 }
TudlaAccounting::Contact.create!(organization: org, name: "Cloudnine Hosting", kind: "supplier", email: "billing@cloudnine.test",
                                 payment_terms_days: 30, default_account: TudlaAccounting::Account.find_by!(organization: org, code: "6020"),
                                 default_tax_code: TudlaAccounting::TaxCode.find_by!(organization: org, code: "GST-P"))
```

A contact with invoices, bills or payments can't be deleted; make it inactive instead (`active: false`), and it keeps its history but isn't offered for new documents.

## 8. Import open receivables and payables

When moving from another system, import the invoices and bills still unpaid at the cut-over. That way the aging report is right from day one, and later payments can be applied to them. The opening balances already include these amounts, so the import records them without changing any balance.

This needs the receivable and payable roles from step 4. The CSV has these columns:

```csv
particulars,amount,type,due_date,other_currency,other_currency_amount,transaction_rate,conversion_date
Invoice 1001,"1,000.00",receivable,2026-01-15,,,,
Bill 2001,500,payable,2026-01-20,,,,
Invoice 1002 (EUR),154.00,receivable,2026-01-25,EUR,100.00,1.54,2025-12-20
```

- `amount` is always in the organization's currency.
- Foreign-currency rows also give the foreign amount and the rate they were booked at. They go to a currency sub-account of the receivable or payable account (`1100-EUR`), which is created if needed.
- See `spec/fixtures/files/carrying_amounts.csv` for a full example.

**In the UI:** Setup → Open receivables and payables. Choose:

- the file;
- the day before the cut-over;
- the income account and the expense account to offset receivables and payables against.

**In the console:**

```ruby
TudlaAccounting::CarryingAmountsCreator.call(
  organization: org, csv_file: "open_items.csv", date_prior: Date.new(2025, 12, 31),
  sales_account_code: "4010", purchase_account_code: "6000"
)
```

The whole file imports or nothing does. Pass `source: ->(row) { Invoice.create!(number: row[:particulars]) }` to turn each row into a host record, which becomes the entry's source (and gives the related party through the `related_party_method` setting).

## 9. Check the books

Look over the opening position first:

- the balance sheet and trial balance for the first month, under Reports;
- the receivables and payables aging, if you imported open items.

Then compare the stored balances with what the posted entries and opening balances add up to.

**In the UI:** Setup → Check balances lists any stored balance that differs, and can rebuild them.

**In the console:**

```ruby
TudlaAccounting::BalanceRebuilder.new(org).differences  # [] when they agree
TudlaAccounting::BalanceRebuilder.new(org).rebuild!     # rewrites the stored balances; returns how many changed
```

**With rake**, for every organization with accounts, or one organization with `ORGANIZATION=Type:id`:

```bash
bin/rails tudla_accounting:balances:check                              # lists differences; exits 1 if there are any
bin/rails tudla_accounting:balances:rebuild ORGANIZATION=Organization:42
```

`balances:check` suits a nightly job or CI. A rebuild never touches entries.

The books are now ready. Record entries under Entries, or from host records with `TudlaAccounting.create_entry_from_source!` (see the [README](README.md#entries-from-host-app-records)).

---

## Revaluing foreign currency

At a month end, open foreign-currency receivables and payables can be revalued at that day's rate. The unrealized gain or loss is posted to the `unrealized_fx_gain` account and reversed the next day. Running it again for the same date does nothing more.

Rates stored in `TudlaAccounting::ForexRate` are used first (one per currency pair and day; the inverse pair works too), and the `forex_rate_provider` setting supplies and stores any that are missing. Without either, revaluation refuses to run and names the missing rate. To record a rate by hand: `TudlaAccounting::ForexRate.create!(from: "EUR", to: "USD", year: 2026, month: 3, day: 31, rate: "1.6")`.

**In the UI:** Setup → Foreign exchange revaluation; choose a month that has ended.

**In the console:**

```ruby
TudlaAccounting::RevaluationEntryGenerator.call(org, Date.new(2026, 3, 31), Date.new(2026, 4, 1)) # => the entries posted
```

## Closing periods

Closing a period stops anything more being posted into it.

- **Order:** months close in order, and a year closes with all its months.
- **Reopening:** only the most recently closed period can be reopened, and it needs a reason, which is kept in the audit trail.

**In the UI:** Periods, then the year; use Close or Reopen on a month or the year.

**In the console:**

```ruby
month = year.children.order(:from_date).first
month.close_blocker         # why closing would be refused, or nil
month.close!
month.reopen!(reason: "Late supplier bill")
```

## The next year

Create the year before posting into it, either in the UI (Periods → New financial year) or with `PeriodCreator.call(org, 2027)`. There's no closing step at year end:

- asset, liability and equity balances carry forward;
- income and expenses restart at zero;
- the year's profit is added to the retained earnings account.

Entries back-dated into an earlier year keep the later years correct.
