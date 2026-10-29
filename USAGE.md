<!--
This guide is tested. spec/integration/usage_guide_spec.rb runs its ```ruby blocks in order as
one console session, picking them by the heading they're under, with Organization.find(1)
swapped for the spec's organization, and runs its `bin/rails tudla_accounting:*` lines as rake
tasks. spec/system/usage_guide_spec.rb follows the UI steps by the labels they name. Keep each
Ruby block runnable after the ones before it (write alternatives as comments), and update both
specs when a heading or a label changes.
-->

# Setting up the books

This guide takes an organization from nothing to books ready for day-to-day posting, then through keeping them: invoicing, paying and being paid, the bank, budgets and the month and year end. Each step can be done in the engine's pages or from a Rails console (or `bin/rails runner`), and the steps go in this order:

1. [Install the engine](#1-install-the-engine) (once per host app)
2. [Create a financial year](#2-create-a-financial-year)
3. [Load the chart of accounts](#3-load-the-chart-of-accounts)
4. [Mark the accounts the books treat specially](#4-mark-the-accounts-the-books-treat-specially)
5. [Enter opening balances](#5-enter-opening-balances)
6. [Add tax codes and dimensions](#6-add-tax-codes-and-dimensions) (optional)
7. [Add customers and suppliers](#7-add-customers-and-suppliers) (optional)
8. [Import open receivables and payables](#8-import-open-receivables-and-payables) (optional)
9. [Check the books](#9-check-the-books)

Then [running the books](#running-the-books):

- [invoices and bills](#invoices-and-bills);
- [payments, credits and refunds](#payments-credits-and-refunds);
- [recurring invoices](#recurring-invoices);
- [paying suppliers](#paying-suppliers);
- [statements and reminders](#statements-and-reminders);
- [banking](#banking);
- [budgets](#budgets);
- and at month and year end, [revaluing foreign currency](#revaluing-foreign-currency), [closing periods](#closing-periods) and [the next year](#the-next-year).

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

Receivables and payables cover the marked account and every account beneath it. The marked account is the total of a sub-account for each currency, and holds nothing of its own: giving the role makes the sub-account in the organization's currency (`1100-USD`, given the account's own opening balance), and the first invoice, bill or payment in another currency makes that currency's (`1100-EUR`). `Account.for_role_in_currency!(org, :receivable, "USD")` finds the one to post to. An account already in the organization's currency beneath the marked account serves as its sub-account, and the role is refused when the code it would make is taken by an account elsewhere.

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

# Running the books

Day to day, the books are kept by recording what the organization sells and buys, what it is paid and pays, and what the bank says happened. These sections go through each, then the month-end and year-end jobs. They follow on from the setup above: the console examples use its accounts, tax codes and contacts, and the money moves through the bank account `1010`.

## Invoices and bills

An invoice (to a customer), a bill (from a supplier) and a credit note against either are **documents**. A document starts as a draft, which can be changed or deleted. Approving it numbers it (`INV-0001`, `BILL-0001`) and posts its entry: the total to the receivable or payable account, each line's amount and tax to its accounts. After that it doesn't change; voiding it reverses its entry.

Each line has a description, quantity, unit price, account and optional tax code and dimension values. Prices exclude the tax unless the document says they include it. A document in another currency gives the rate to the organization's currency, or leaves it blank for the date's rate from the `forex_rate_provider` setting, and goes to a sub-account of the receivable or payable account in that currency, such as `1100-EUR`.

**In the UI:** Sales → New invoice, or Purchases → New bill. Choosing the customer or supplier fills in the due date from their payment terms, and each line's account and tax code from their defaults; the totals add up as the lines are typed. **Save draft** or **Save and approve**. An approved document's page offers Record payment, Email, a credit note, and (with Active Storage) Attach files, for a supplier's PDF.

**In the console:**

```ruby
sales = TudlaAccounting::Account.find_by!(organization: org, code: "4010")
gst_on_sales = TudlaAccounting::TaxCode.find_by!(organization: org, code: "GST")
northwind = TudlaAccounting::Contact.find_by!(organization: org, name: "Northwind Traders")
invoice = TudlaAccounting::Document.create!(
  organization: org, kind: "sales_invoice", contact: northwind, issued_on: Date.new(2026, 6, 1), due_on: northwind.due_on(Date.new(2026, 6, 1)),
  lines_attributes: [ { description: "Consulting, May", quantity: 10, unit_price_cents: 150_00, account: sales, tax_code: gst_on_sales,
                        dimension_value_ids: [ department.dimension_values.find_by!(code: "SALES").id ] } ]
)
invoice.approve!        # numbered INV-0001 and posted
invoice.total           # $1,650.00, with the tax
invoice.payment_status  # "unpaid"

cloudnine = TudlaAccounting::Contact.find_by!(organization: org, name: "Cloudnine Hosting")
bill = TudlaAccounting::Document.create!(
  organization: org, kind: "bill", contact: cloudnine, reference: "CN-7781", issued_on: Date.new(2026, 6, 2), due_on: cloudnine.due_on(Date.new(2026, 6, 2)),
  lines_attributes: [ { description: "Hosting, June", quantity: 1, unit_price_cents: 200_00, account: cloudnine.default_account, tax_code: cloudnine.default_tax_code } ]
)
bill.approve!           # BILL-0001, $220.00

globex = TudlaAccounting::Contact.find_by!(organization: org, name: "Globex")
euro_invoice = TudlaAccounting::Document.create!(
  organization: org, kind: "sales_invoice", contact: globex, currency: "EUR", exchange_rate: "1.08", issued_on: Date.new(2026, 5, 1), due_on: globex.due_on(Date.new(2026, 5, 1)),
  lines_attributes: [ { description: "Licence", quantity: 1, unit_price_cents: 1_000_00, account: sales } ]
)
euro_invoice.approve!   # INV-0002: EUR 1,000.00, posted as $1,080.00 to 1100-EUR
# euro_invoice.void!(on: Date.current, reason: "Issued twice") would reverse its entry
```

Only drafts can be deleted. A void is refused while payments or credit notes are applied to the document.

## Payments, credits and refunds

A payment is money received from a customer or paid to a supplier, through a bank or cash account. Recording one posts it at once, and applies it to the invoices or bills given; whatever isn't applied stays as a **credit** for the contact, to apply later or refund. A credit note is applied to the invoice or bill it credits as far as that is still owed.

**In the UI:**

- **Record payment** on an approved invoice or bill (or Sales → Payments received, Purchases → Payments made) lists the contact's open invoices or bills, oldest due first, with an amount to apply to each. It can email a receipt, or a payment notice, at the same time.
- **Credit note** on an approved invoice (Supplier credit on a bill) starts one with its lines.
- A payment or credit note with something left offers to apply it to the contact's other open items, or to refund it (**Refund to them**, **Record their refund**).

**In the console:**

```ruby
bank = TudlaAccounting::Account.find_by!(organization: org, code: "1010")
payment = TudlaAccounting::Payment.record!(organization: org, kind: "received", contact: northwind, account: bank, paid_on: Date.new(2026, 6, 12),
                                           amount_cents: 1_700_00, reference: "EFT 88213", applications: [ { document: invoice, amount_cents: 1_650_00 } ])
invoice.reload.payment_status # "paid"
payment.unapplied             # $50.00, a credit for Northwind
TudlaAccounting::Payment.record!(organization: org, kind: "refund", contact: northwind, account: bank, paid_on: Date.new(2026, 6, 13),
                                 amount_cents: 50_00, refund_of: payment)

credit = TudlaAccounting::Document.create!(
  organization: org, kind: "supplier_credit", contact: cloudnine, credited_document: bill, issued_on: Date.new(2026, 6, 5),
  lines_attributes: [ { description: "Outage credit", quantity: 1, unit_price_cents: 20_00, account: cloudnine.default_account, tax_code: cloudnine.default_tax_code } ]
)
credit.approve!          # SC-0001, applied to the bill straight away
bill.reload.amount_due   # $198.00
```

A payment in another currency goes through a bank account held in it, and applies only to documents in that currency; any difference from the rate they were booked at is posted to the `realized_fx_gain` account. A payment isn't changed or deleted once recorded: `payment.void!(on:, reason:)` reverses it, and takes it off what it paid.

## Recurring invoices

A recurring invoice makes the same invoice on a schedule: every N weeks, months or years from a start date, until an end date or a number of invoices. Each one is left as a draft, approved, or approved and emailed to the customer.

**In the UI:** Sales → Recurring invoices → New recurring invoice, or **Repeat** on an approved invoice. The list's **Make the N due invoices now** makes those due.

**In the console:**

```ruby
retainer = TudlaAccounting::RecurringInvoice.create!(
  organization: org, name: "Globex support", contact: globex, frequency: "monthly", day_of_month: 1, starts_on: Date.new(2026, 6, 1), issue: "approve",
  lines_attributes: [ { description: "Support retainer", quantity: 1, unit_price_cents: 500_00, account: sales, tax_code: gst_on_sales } ]
)
TudlaAccounting::RecurringInvoiceRunner.call(organization: org) # makes every invoice due by today; here June's, approved
retainer.reload.next_on # 1 July 2026
```

Schedule `TudlaAccounting::RecurringInvoicesJob` to run them every day (see the [README](README.md#recurring-invoices)). A date is never invoiced twice, and an invoice that can't be made or approved is left, with the reason on the template's page and the dashboard.

## Paying suppliers

A **pay run** pays a batch of bills from one bank account: one payment to each supplier, applied to their bills, with each supplier's payment notice emailed.

**In the UI:** Purchases → Pay run lists the bills due by a date (a week from today by default), grouped by supplier and all ticked. Untick any, change what is paid of each, give the date and a reference, then **Pay the chosen bills**.

**In the console:**

```ruby
due = TudlaAccounting::PayRun.due(org, currency: org.currency, due_by: Date.new(2026, 7, 15)) # => [bill]
TudlaAccounting::PayRun.call(organization: org, account: bank, paid_on: Date.new(2026, 6, 15), reference: "Pay run 15 June",
                             bills: due.map { |due_bill| { document: due_bill, amount_cents: due_bill.amount_due.cents } }, email: true)
# => #<Result payments=[...] emailed=[...] no_address=[...]>
```

All the payments are recorded or none. Bills imported in step 8 are open payables, not documents, so they're paid with **Record payment** on the supplier's page instead.

## Statements and reminders

A **statement** shows a customer (or supplier) what they owed at the start of a run of days, each invoice, payment and credit since, and what they owe at the end, by how overdue. **Reminders** email customers about overdue invoices on the days after the due date that the `reminder_days` setting names.

**In the UI:**

- **Statements:** Reports → Statements, or the Statement link on a contact's page. It prints, downloads as CSV or Excel, and has an Email button; **All customers** shows and emails every statement with something to send.
- **Reminders:** Sales → Reminders due lists them, and **Send N reminders** sends them all. An overdue invoice's page has **Send reminder**.

**In the console:**

```ruby
statement = TudlaAccounting::PartyStatement.call(organization: org, type: :receivable, party: northwind, from: Date.new(2026, 6, 1), thru: Date.new(2026, 6, 30))
statement.closing.zero? # true: invoiced, paid, and the overpayment refunded

TudlaAccounting::ReminderRunner.due(organization: org)  # => [#<Reminder invoice=INV-0002 days=14 ...>] with reminder_days = [7, 14, 30]
TudlaAccounting::ReminderRunner.call(organization: org) # emails them
```

Schedule `TudlaAccounting::SendRemindersJob` to send them every day. Each reminder goes once; one for an invoice since paid or voided doesn't go.

## Banking

Importing the bank's statement and matching its lines to the books shows what the books are missing, and that they agree with the bank.

- **Importing:** CSV, OFX, QFX or CAMT.053 files. Lines already imported are skipped, so statements can overlap.
- **Matching:** each statement line with a posted line on the bank account for the same amount within a week is suggested, and can be matched.
- **Recording:** a line the books don't have yet can be recorded as an entry against another account, or as a payment of an open invoice or bill. **Bank rules** say how to record lines by their description, such as the bank's fees.

**In the UI:** Banking, then the account. Choose the file and how its dates and amounts are written, and **Import statement**. **Match N suggestions** matches the suggested pairs, and **Record N lines by their rules** records the lines a rule suggests; Bank rules, on the same page, adds the rules. An unmatched line can also be matched by hand, posted as an entry, or recorded as a payment. The page shows the reconciliation: the balance in the books against the bank's.

**In the console:**

```ruby
TudlaAccounting::BankStatementImporter.call(bank, "statement.csv", date_order: :dmy, decimal_mark: ".") # => { imported: 4, skipped: 0, format: :csv }
TudlaAccounting::BankRule.create!(organization: org, name: "Bank fees", description_contains: "account fee", direction: "out",
                                  counter_account: TudlaAccounting::Account.find_by!(organization: org, code: "6000"))
reconciler = TudlaAccounting::BankReconciler.new(bank)
reconciler.match_suggestions! # the payments, the refund and the pay run, matched to their entries
reconciler.record_by_rules!   # the fee, posted against 6000
reconciler.summary(as_of: Date.new(2026, 6, 30))[:difference] # $0.00: the books agree with the bank's balance
```

The statement file has a date, a description and an amount (or money in and money out) in each row, and optionally a reference and the running balance:

```csv
Date,Description,Amount,Reference,Balance
12/06/2026,NORTHWIND TRADERS EFT,1700.00,EFT 88213,26700.00
13/06/2026,REFUND NORTHWIND TRADERS,-50.00,,26650.00
14/06/2026,MONTHLY ACCOUNT FEE,-12.50,,26637.50
15/06/2026,CLOUDNINE HOSTING,-198.00,Pay run 15 June,26439.50
```

See `spec/fixtures/files/bank_statement.csv` for this example, and the [README](README.md#bank-reconciliation) for the columns and formats it reads.

## Budgets

A budget is an amount for each income and expense account in each month of a year. The profit and loss compares the actual results with it.

**In the UI:** Reports → Budgets → New budget, then **Add budget**. It starts blank, from a year's actual results changed by a percentage, or as a copy of another budget. Its grid has the accounts down the side and the months across, and an amount typed in the Year column is spread over the months. A budget downloads as a spreadsheet and uploads again. The profit and loss's **Compare with** shows a budget against the actual results.

**In the console:**

```ruby
budget = TudlaAccounting::Budget.create!(organization: org, period: year, name: "2026", main: true)
months = year.children.order(:from_date)
budget.set_amounts!(sales.id => months.to_h { |month| [ month.id, 2_000_00 ] }, cloudnine.default_account.id => months.to_h { |month| [ month.id, 200_00 ] })
TudlaAccounting::Reports::BudgetComparison.new(budget, year) # actual, budget, and the variance for each account
# Next year's, from this year's results plus 5%: budget.fill_from_actuals!(year, percent: 5)
```

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
