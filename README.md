# TudlaAccounting

A double-entry general ledger for Rails apps, packaged as a mountable **Rails 8.1 engine**. Add it to a host app to get a chart of accounts, balanced journal entries, and account balances that roll up through account and period hierarchies. It can also track receivables and payables, including in foreign currencies, and supports multiple organizations.

## What it does

### Chart of accounts
`TudlaAccounting::Account` belongs to an organization and has a `code`, a `name`, and a category: `asset`, `liability`, `equity`, `income` or `expense`. Accounts form a tree, e.g. *1100 Accounts Receivable > 1105 AR – EUR customers*. A child must share its parent's category. An account can name a **contra account**, which flips its normal side, e.g. accumulated depreciation against an asset.

**Inactive accounts.** An account with history can't be deleted; `account.deactivate!` makes it, and every account beneath it, inactive instead (`active: false`). Inactive accounts keep their history and balances and still show in reports and ledgers, but aren't offered for new entries: the entry form, the banking forms, and parent, contra and tax account choices leave them out (a draft keeps the inactive accounts its lines already have), and `Entry.create_from_ruby_hash` and `BankReconciler#create_entry!` refuse them. Filters still list them, marked. Drafts written before stay postable, as do the entries the engine makes itself. `deactivation_blocker` says why it would be refused: an account (or one beneath it) holding a role, where an active tax code posts, or with receivables or payables still open. `account.reactivate!` makes one account active again, once its parent is; its sub-accounts stay as they are. Both are on the audit trail (`account.deactivated`, `account.reactivated`), and the account page has buttons for each.

### Accounting periods
`TudlaAccounting::Period` is a date range, and periods also form a tree: a year, then quarters, then months. `TudlaAccounting::PeriodCreator.call(organization, 2026)` builds a financial year and its twelve months in the configured time zone. Each period runs from the start of its first day to the end of its last. Pass a start month and day for a fiscal year, e.g. `PeriodCreator.call(org, 2026, 7, 1)`. `Period.ancestry_check(root)` checks that every period's children exactly cover it, with no gaps or overlaps.

### Journal entries
A `TudlaAccounting::Entry` is made up of `Detail` lines. Each line is a debit or credit of an amount to one account. An entry is only valid if:
- debits equal credits
- it has at least one debit and one credit
- all lines are in one currency

An entry can point at a `source` record in the host app, such as the invoice it came from, and a `related` entry, such as the invoice a payment settles. A line can carry a `ForeignExchange` record holding the foreign-currency amount and rate, and a `description` of its own, for entries whose lines each record something different (a payroll's deductions, an expense claim's receipts).

**Numbers and references.** Posting gives an entry the next **journal number** of its series (`number`, shown by `number_label`, e.g. `#42`). Drafts have none, and posted entries are never deleted, so the numbers have no gaps; a post that is rolled back gives its number back. Two settings choose how entries are numbered and shown, and both can change at any time: entries already posted keep their numbers, and each series counts from 1 on its own.
- `entry_number_series`: `:organization` (one run per organization, the default), `:financial_year` (restarting each year; the series is the year it ends in, e.g. `"2027"` for July 2026 to June 2027), or a callable given the entry being posted, e.g. `->(entry) { entry.source_type == "Invoice" ? "INV" : "JE" }`.
- `entry_number_format`: a format string given `number` and `series` (default `"#%{number}"`; e.g. `"JE-%{series}-%<number>05d"` for `JE-2027-00042`), or a callable given the entry.

An entry's `reference` is free text from elsewhere, such as a cheque number or the supplier's invoice number. Like the rest of an entry, both are fixed once it is posted; a reversal keeps the reference and takes its own number. Reversals keep the lines' descriptions too, and an entry made from a bank statement line under other particulars keeps the statement's description on the bank line. The entries page searches particulars, references, line descriptions and numbers (`42`, `#42` or `JE-00042`).

`Entry.create_from_ruby_hash` builds an entry from plain data (with an optional `reference:`, and a `description:` on any line). You give account codes and **signed** amounts, and it works out whether each line is a debit or credit from the account's normal side. Positive increases the account; negative decreases it.

**Auto-reversing entries.** An accrual or prepayment can undo itself: give a draft a `reverse_on` date (the entry form's "Reverse automatically on", or `reverse_on: "2026-04-01"` in `create_from_ruby_hash`) and posting it posts its reversal too, dated that day, in the same transaction: both or neither. The date must come after the entry's own and have a financial year; an invoice, bill, payment or credit can't have one, since its reversal would close what is owed or take the payment off.

### Recurring entries
`TudlaAccounting::RecurringEntry` is an entry made again and again (rent, a subscription, depreciation, a month-end accrual): its particulars, reference and lines (account, debit or credit, amount, description, tax code, dimension values) and a schedule: every N weeks, months or years from `starts_on`, a monthly or yearly one on `day_of_month` (cut to a short month) or the last day when that is blank, until `ends_on` or `occurrences_limit` entries. Each makes drafts to post, or (`post_automatically`) posts them; with `reverse_next_month` each reverses itself on the first of the next month. Lines refer to accounts, not codes, so renumbering is safe; an account an active one uses can't be made inactive, nor one any uses deleted.

`RecurringEntryRunner.call(organization:, as_of:)` makes every entry due by then (today by default), catching up any missed, each through `Entry.create_from_ruby_hash` with the template as its source and `recurring:<id>:<date>` as its idempotency key, so runs that overlap or repeat make each once. One that can't be made (an account made inactive since) stops its template, to try again next run; one that can't be posted (no year for it yet) is left a draft. Either way the reason is kept in `last_problem`, shown on its page and the dashboard. `TudlaAccounting::RecurringEntriesJob` runs it for every organization; schedule it in the host app, e.g. with Solid Queue's `config/recurring.yml`:

```yaml
production:
  tudla_accounting_recurring_entries:
    class: TudlaAccounting::RecurringEntriesJob
    schedule: every day at 1am
```

The **Recurring entries** page (from Entries) lists them with their schedule and next date, makes the due ones now, and adds, edits, deactivates and deletes them with the entry form's line editor; an entry's **Make recurring** starts one from its lines, and a template's **Make a draft for today** makes a one-off entry from it. They are on the audit trail, as is each entry made.

### Attachments
With Active Storage set up in the host app (`bin/rails active_storage:install`), entries can carry receipts and other source documents; `TudlaAccounting.attachments?` says whether they can, and the pages leave attachments out until then. The engine ships no Active Storage migration of its own.

- `entry.add_attachments!(files)` attaches uploaded files, or hashes of `io:`, `filename:` and `content_type:`, to a draft or a posted entry (a receipt often arrives after the entry is posted). Each must be of a type in the `attachment_content_types` setting, as Active Storage identifies it from the file's contents (by default PDF, PNG, JPEG, HEIC, WebP, CSV, Excel and email), and no bigger than `attachment_max_size` (10 MB by default); otherwise nothing is attached.
- `entry.remove_attachment!(attachment, reason: nil)` removes one: freely from a draft, but from a posted entry only with a reason, since its files are part of its record.
- Both are on the audit trail (`entry.attachment_added`, `entry.attachment_removed`) with the file's name, size and checksum, and the reason. Attach and remove files with these methods rather than `entry.attachments.attach`, which skips the checks and the trail. A draft deleted takes its files with it.

The entry page lists an entry's files, uploads more (`:record` permission) and removes them: a draft's with `:record`, a posted entry's with `:administer` and a reason. Files are served through the engine (`/entries/:id/attachments/:id`), which checks the permissions and the organization. Active Storage's own routes serve a file to anyone with its signed URL, so the engine's pages never link to them; keep that in mind if the host app does.

### Posting and balances
`entry.post(posted_at)` posts every line to the period that contains `posted_at`, then stamps the entry. The whole post is one transaction: if any line fails, nothing is posted. Posting an entry twice raises `ArgumentError`. Posts lock the organization's row while they run, so concurrent posts for the same organization take turns instead of overwriting each other's balance updates; other organizations aren't blocked. Each account has one `TudlaAccounting::Balance` per period, holding starting, current and ending amounts. Posting:
- adds the amount to the balance of the deepest period containing `posted_at`, e.g. the month
- rolls it up into every parent period (quarter, year) and every parent account
- carries it forward into the starting amount of every later period, so back-dated entries keep later balances correct

**Year end.** Each top-level period is a financial year, and balances carry across years automatically, with no closing step:
- asset, liability and equity accounts open each year with their closing balance from the year before;
- income and expense accounts start each year at zero;
- the previous year's net profit (income less expenses) is added to the organization's retained earnings account (the one with `role: "retained_earnings"`; see account roles below), and to the accounts above it.

Back-dated entries into an earlier year follow the same rules, so later years stay correct whatever order entries are posted in. `Balance.net_profit(organization, year)` returns a year's profit. Without a retained earnings account, income and expenses still restart each year, but the profit isn't carried, so later years' balance sheets won't balance. Marking one later, moving the role to another account or taking it off rebuilds the organization's balances (see below) as part of the change, so every earlier year's profit lands where it now belongs: a client taken on mid-stream can have its years posted first.

**Account roles.** Each organization marks the accounts the books treat specially, at most one of each, on its own chart: `Account#role` is `receivable` (an asset: what customers owe, with the accounts beneath it), `payable` (a liability), `retained_earnings` (equity), `unrealized_fx_gain` or `realized_fx_gain` (income or expense). Set it in the account form, with a `Role` column in the chart of accounts import, or with `role:` in `AccountsCreator`; `Account.for_role(organization, :receivable)` finds it. Since the engine goes by the role and never by code, accounts can be renumbered freely, and every organization's chart can differ. Roles change only through `AccountRoleAssigner.save(account, role)`, which the form (for those with `:administer`), the import and `AccountsCreator` use; a plain `account.update(role:)` is refused. Taking a role another account holds moves it, except that receivables and payables stay on an account once it, or an account beneath it, has posted lines (its open items would be left behind). See [USAGE.md](USAGE.md) for setting up an organization's books step by step.

**Checking and rebuilding balances.** Balances are a running total kept by posting; the posted entries and the first year's opening balances are the record. `TudlaAccounting::BalanceRebuilder.new(organization).differences` works every balance out again from those, independently of the posting code, and lists any stored figure that differs (or a balance with activity that is missing). `rebuild!` rewrites the stored balances to match, under the same organization lock as posting, and never touches entries. From the command line:

```bash
bin/rails tudla_accounting:balances:check     # lists differences; exits 1 if there are any
bin/rails tudla_accounting:balances:rebuild   # ORGANIZATION=Organization:42 limits either task to one organization
```

### Database integrity
The engine's migrations add unique keys (one balance per account and period, account codes per organization, one carrying amount per line, one exchange rate per currency pair and day) and checks (positive line amounts, known tallies, categories and carrying-amount types). On PostgreSQL, triggers also refuse any change to a posted entry or its lines, or their deletion, from anywhere (a console, a job, raw SQL): correct posted entries by reversing them. Touching `updated_at` is allowed. Triggers likewise refuse posting into a closed period and any change to audit events. Data maintenance that really must change posted rows can run inside `TudlaAccounting::DatabaseProtection.allowing_posted_changes { ... }`, which lifts the protection for that block's transaction only.

Triggers can't be stored in `db/schema.rb`, so the engine reinstalls them whenever Rails loads a schema (`db:schema:load`, `db:prepare`, `db:migrate` on an empty database, the test database being brought up to date); run `bin/rails tudla_accounting:protect_posted_entries` if a database was built some other way.

### Closing periods
`period.close!` closes a month, or a year with all its months. Nothing more can be posted into a closed period: posting, reversing into it, revaluation entries and changes to opening balances in it are refused (and on PostgreSQL a trigger refuses it from anywhere). Periods close in order, each after the earlier ones, so later postings can never move a closed period's balances. `period.reopen!(reason: "...")` reopens the most recently closed period (a year before its months); the reason is kept in the audit trail. `close_blocker` and `reopen_blocker` say why either would be refused.

### Audit trail
Each change to the books records a `TudlaAccounting::AuditEvent`: entries posted, reversed and deleted as drafts; accounts added, changed and deleted; years created and deleted; periods closed and reopened (with the reason); opening balances saved; and balance rebuilds. Each event keeps who acted, the subject, any details, and labels for both, so it still reads after they are gone. Events can't be changed or deleted (a trigger on PostgreSQL).

Who acted comes from `TudlaAccounting::Current.actor`: the engine's pages set it from the `current_actor` setting, and other code can set it around its work with `TudlaAccounting::Current.set(actor: user) { ... }`. The actor can be a record (labelled by its `name` or `email`) or a plain string; events without one show as "System".

### Tax
`TudlaAccounting::TaxCode` records each tax lines can be taxed under: a code, a rate, whether it is on **sales** (tax collected) or **purchases** (tax paid), and the account the tax is posted to (a zero-rate code, such as GST-free, needs none but is still reported). Codes are managed under Setup → Tax codes; once lines are taxed under a code it can be made inactive but not deleted or switched between sales and purchases.

In `Entry.create_from_ruby_hash`, a line with `tax_code: "GST"` is taxed: its amount excludes the tax, and a line for the tax is added on the code's account, on the same side, so the other lines must include it (e.g. receivable 110, sales 100 with GST). With `tax_inclusive: true` (on the line or the whole hash) the amount includes the tax and is split instead, leaving the totals unchanged. Taxed lines and tax lines are tagged with the code (`tax_role` base or tax), and reversals keep the tags. Tax is always in the organization's currency: on a line with a foreign amount it is worked out on the converted amount and posted without a foreign amount (an inclusive line's foreign amount is split the same way), and a tax account held in another currency is refused.

The entry form has a Tax column once the organization has tax codes: the totals and the balanced check include the tax as amounts are typed (or, with "amounts include the tax", split it out), and saving adds one tax line per code and side, replacing the ones saved before.

`TaxReport.call(organization, from:, thru:)` (Reports → Tax summary) totals, per code, the amounts taxed and the tax for lines posted in that time: sales codes count credits up, purchases codes debits, so credit notes and reversals reduce their own side. `net_tax` is tax on sales less tax on purchases: owed when positive, a refund when negative.

By default tax counts when its lines are posted (accrual basis). With `basis: :cash` (or the `tax_basis` setting, or the page's Basis choice) it counts when money changes hands: entries that open no receivable or payable count when posted, while an invoice's, bill's or taxed credit note's tax counts in proportion as payments and credits are applied to it (by its foreign amount when it has one), back out if one is taken off, and the reversal of an invoice or bill isn't counted.

### Comparative statements
`Reports::Comparison.new(Reports::ProfitAndLoss, organization, periods)` (or `Reports::BalanceSheet`) puts a statement for several periods side by side, in the order given: `rows(category)` gives each account with an amount per period (an account shows when it has something in any of them), `total(category)` a total per period, and `values(:net_profit)` (or `:total_equity`, `:current_year_earnings`...) a figure per period. On the balance sheet and profit and loss pages, **Compare with** puts the period beside the previous one or the same one a year earlier, with the change and the percentage change, or shows each month of the year: the month ends so far on the balance sheet, and each month and the year's total in a year's profit and loss.

### Exporting reports
Every report downloads as CSV, as shown on its page (period, comparison, months, basis, cash accounts): the pages' **Download CSV** link, or the report's path with `.csv`. With the `caxlsx` gem in the host app's Gemfile (the engine doesn't depend on it; `TudlaAccounting.xlsx?` says whether it's there), the pages also offer **Excel** (`.xlsx`): one sheet, amounts as numbers in an accounting format, dates as dates, text never read as a formula, and the headings and totals in bold. **Print or save as PDF** opens the browser's print dialog: printed pages leave out the navigation, forms and buttons, use light colours whatever the theme, name the organization and when it was printed, print every column of a wide table, and turn landscape for a comparison of more than three periods. `Reports::Tables` lays each report out as a `Reports::Table` (`statement`, `trial_balance`, `aging`, `tax`, `by_dimension`, `cash_flow`; `Reports::GeneralLedger#to_table`), whose `to_xlsx(sheet_name)` writes the workbook and `to_csv` writes amounts as plain numbers (`-1234.50`) and dates as ISO 8601. Text that a spreadsheet would run as a formula (an account or party name starting with `=`, `+`, `-` or `@`) is written with a leading apostrophe. Statements have a row per account with its section, code and level in the tree, then the totals; the aging report has a row per open item, its amount in its bucket's column.

### General ledger and cash flow
`Reports::GeneralLedger.new(organization, from: month, thru: month, account_ids: nil)` lists, for every account lines are posted to (or the ones chosen), the opening balance, each posted line with a running balance on the account's own side, and the closing balance; `to_csv` writes it out, with each line's entry number, reference and description. Reports → General ledger shows it and downloads the CSV.

`Reports::CashFlow.new(organization, from:, thru:, cash_accounts: nil)` is a direct-method cash flow statement: each posted entry that moves cash is attributed to its other lines, grouped by their account's **cash flow activity** — operating, investing or financing, set on the account (inherited from its parent when blank; equity defaults to financing, everything else to operating). Moves between cash accounts cancel out, and `reconciles?` checks that opening cash plus the net change is the closing cash. Cash is the `cash_accounts` given or the `cash_account_codes` setting (each with its sub-accounts); Reports → Cash flow lets you pick them too. With `method: :indirect` (the page's Method choice) it starts instead from the net profit and adds each other balance-sheet account's change over the time, by its activity (receivables growing take cash, payables growing give it); income and expense accounts all count in the net profit, so set accumulated depreciation's activity to operating to show depreciation added back there. Both methods come from the same posted lines and give the same totals.

### Reporting dimensions
`TudlaAccounting::Dimension`s (department, project, location...) each have `DimensionValue`s, managed under Setup → Dimensions; inactive ones stop being offered but stay on the lines that have them. Entry lines are tagged with at most one value of each dimension (`DetailTag`): in `Entry.create_from_ruby_hash` with `dimensions: { "DEPT" => "SALES", "PROJ" => "APOLLO" }` on a line (codes), or with a column per dimension in the entry form. Reversals keep the tags; tax lines aren't tagged.

`DimensionReport.call(organization, dimension, from:, thru:)` (Reports → Profit and loss by dimension) breaks income and expenses posted in that time down by the dimension's values, with an "Untagged" column for lines without one and a total, and the net profit of each.

### Bank reconciliation
`BankStatementImporter.call(account, path, date_order: :dmy)` imports a bank statement for an account as `BankStatementLine`s (money in positive, money out negative, in the account's currency), and says how many it imported and skipped and the format it read. It tells the formats apart by what the file holds:
- **CSV:** it finds columns by their usual headers: a date, a description, one signed amount or money in and out columns, and optionally a reference, the running balance and the bank's transaction id.
- **OFX and QFX** (the SGML of OFX 1.x, in Windows-1252 or UTF-8, or the XML of 2.x; bank or credit card): each transaction by its `FITID`, described by its name and memo, with its cheque or reference number.
- **ISO 20022 CAMT.053:** each booked entry (pending ones are left out) by the bank's reference, described by the remittance information or the other party's name, with the end-to-end id as its reference.

An OFX or CAMT file must be for one account and in the account's currency, and its closing balance goes on its last line, for the reconciliation summary. Lines already imported are skipped, so overlapping statements can be imported safely.

`BankReconciler.new(account)` matches statement lines to the posted ledger lines on the account (`BankMatch`; posted lines themselves are never changed):
- `suggestions` pairs each unmatched statement line with an unmatched ledger line for the same amount within a week (the closest), and `match_suggestions!` matches them all.
- `match!(line, ledger_lines)` matches one statement line to one or more ledger lines adding up to it; `unmatch!(line)` takes it off.
- `create_entry!(line, account:)` posts an entry for something the books don't have yet (a bank fee, interest) against another account, dated with the statement line, and matches it.
- **Bank rules** (`TudlaAccounting::BankRule`) say how to record lines the books don't have yet: a line whose description contains some text (in any case), optionally money in or out, within an amount range, on one bank account or any, is recorded against an account, with an optional tax code (the line's amount includes the tax, which is split out) and dimension values, under the rule's particulars or the line's description. Rules apply in order (`position`); the first that matches is a line's rule. They only suggest: `rule_suggestions` pairs each unmatched line with no suggested ledger line with its rule, `record_by_rule!(line, rule)` records one, and `record_by_rules!` records them all, leaving any it can't (a foreign line with no rate) and saying why. `create_entry!` takes the same `tax_code:` and `dimension_values:` (tax only for an account in the organization's currency). An account a rule uses can't be made inactive or deleted, nor its tax code deleted.
- `summary(as_of:)` shows whether the books agree with the bank: the book balance (opening balance plus posted lines), less ledger lines not on the statement, plus statement lines not in the books, against the balance on the latest statement line, and the difference.

A foreign-currency account's ledger lines are compared by their foreign amount, and it has no book balance in its own currency. An entry created from one of its statement lines is in the organization's currency, converted at the rate given (`create_entry!(line, account:, rate:)`, or the Rate field) or else the rate provider's rate for the line's date; the bank line carries the statement amount as its foreign amount, and so does the other line when its account is held in the same currency. Imports, matches and rules are on the audit trail. The **Banking** page does all of this per account: each line a rule suggests shows it with a Record button, Record N lines by their rules records them all, and Create a rule from it starts one from a line; **Bank rules** lists and edits them.

### Receivables and payables (carrying amounts)
After posting, `CarryingAmountProcessor` keeps track of what's still owed. Posting an entry whose source is an invoice or bill opens a `CarryingAmount` on its receivable or payable line (on the account marked `receivable` or `payable`, or one beneath it), with a due date and any foreign-currency amount. Posting a payment, disbursement or credit note opens a **credit** for the customer or supplier: a carrying amount on its line with a negative amount. If money moves through a bank account held in another currency (`BankAccountBalance`), that balance is updated in its own currency.

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
- **Settlement at a different rate.** When a foreign-currency payment or credit is applied to a foreign-currency invoice or bill, its carrying amount goes down by the book value of the foreign amount, at the rate it was booked at. The difference from the credit's own value for that foreign amount is posted as a realized exchange gain or loss to the account marked `realized_fx_gain`, dated with the allocation (and reversed if the allocation is taken off). Each part payment books its own share, and the final one books what remains, so the receivable or payable ends at zero. An overpayment books a gain or loss only on what was owed, and leaves the extra as a credit in the foreign currency. Without that account, the carrying amount is still correct, but the difference stays on the receivable or payable account and a warning is logged.
- **`RevaluationEntryGenerator.call(organization, period_end, next_period_start)`** revalues open foreign-currency receivables and payables at the period-end rate. It posts the unrealized gain or loss to the account marked `unrealized_fx_gain` (needed only when there's something to revalue), then posts a reversal on the next period's start, so the later settlement isn't double-counted. Running it twice for the same date does nothing more.

### Multi-tenancy
Accounts, periods, entries, lines and balances all belong to a polymorphic `organization`, provided by the host app. The organization must respond to `currency`, which is the currency its books are kept in.

## Web pages

Mounted at `/accounting` by the install generator (see [Integration](#integration-into-a-host-application)), the engine has pages for the organization returned by `current_organization`:

- **Dashboard:** profit this year, what is owed each way, draft entries, recent entries, and a getting-started checklist.
- **Accounts:** the chart of accounts as a tree with closing balances. Each account page shows monthly balances and a ledger with running balances. You can create, edit and delete unused accounts, and make accounts no longer used inactive (or active again).
- **Entries:** search entries (by particulars, reference or number) and filter them, attach receipts, write drafts with a line editor that keeps live debit/credit totals, post them, and reverse posted entries. A posted payment or credit note shows what it was applied to and what is left, with forms to apply it to the party's open invoices or bills (or oldest first) and to take an allocation off; an invoice or bill shows what was applied to it. Reversing a payment takes it off what it settled and reverses its realized exchange difference. An invoice or bill can be reversed once nothing is applied to it, which closes its receivable or payable.
- **Banking:** import bank statements, see where the books and the bank stand on a date, match statement lines to the books (suggested matches in one click), post entries for bank fees and the like, and see what is in the books but not yet on a statement.
- **Reports:** balance sheet and profit and loss (alone or compared with the previous period, the year before, or month by month), trial balance, receivables and payables aging, a tax summary for a run of months, profit and loss by dimension, a cash flow statement, and the general ledger, each also as CSV.
- **Periods:** create calendar or fiscal years, see each year's months, and close or reopen them (reopening asks for a reason).
- **Setup:** upload a chart of accounts with opening balances (CSV or Excel), or enter or correct opening balances account by account, with live totals checking that they balance. Manage tax codes and reporting dimensions. Also import the receivables and payables open at the cut-over, and run the foreign exchange revaluation. A balance check compares the stored balances with the posted entries and can rebuild them.
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
- **PostgreSQL** (the ledger's integrity checks and triggers rely on it)
- Works with any Active Job backend; with **Solid Queue**, background posting jobs for an organization run one at a time (the dummy app runs the Solid trifecta)
- **Tailwind CSS v4** for engine views (no DaisyUI dependency) and **Importmap Rails**
- **RSpec**, **FactoryBot**, **SimpleCov** (100% line coverage), **Capybara**
- **RuboCop** with `rubocop-rails-omakase`
- A full dummy Rails app in `spec/dummy/` for running the engine

## Getting Started

TudlaAccounting is pre-1.0 and no version has been published yet: the tags (0.1.0, 0.2.0) are milestones, and later versions don't support upgrading from them. Start from a fresh install.

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

### Benchmark
`perf/benchmark.rb` builds a throwaway organization's books (two years, a chart of 30 accounts, taxed and tagged entries on random dates), then times posting and every report and heavy page, with the number of SQL queries each takes. It checks the balances against the posted lines with `BalanceRebuilder`, and deletes the books afterwards (unless `KEEP=1`):

```bash
docker compose exec rails bash -lc 'ENTRIES=10000 bin/rails runner perf/benchmark.rb'
```

With 10,000 entries (25,000 lines) posting takes about 21 ms an entry, and every report and page answers in under half a second; reports read balances for all accounts in a handful of queries, and the general ledger and banking pages show their lines a page at a time.

### Linting
```bash
docker compose exec rails bash -lc 'bundle exec rubocop'     # Check code style
docker compose exec rails bash -lc 'bundle exec rubocop -a'  # Auto-fix offenses
```

### Continuous integration
`.github/workflows/ci.yml` runs RuboCop, the whole suite and the demo's specs (system specs in headless Chrome) against PostgreSQL, and a strict `gem build` on every push and pull request. The test job sets up the databases with `bin/rails db:create db:schema:load` and points the dummy app at them through `DATABASE_HOST`, `DATABASE_USERNAME` and `DATABASE_PASSWORD`.

### Dummy App (Development Server)
```bash
docker compose exec rails bash -lc 'bin/setup'                                                    # First-time DB setup
docker compose exec -d rails bash -lc 'bin/dev'                                                   # Start dev server (background)
docker compose exec rails bash -lc "ps aux | grep -E 'foreman' | grep -v grep"                   # Check if running
docker compose exec rails bash -lc 'pkill -f foreman || true'                                     # Stop dev server
```

### Demo
The dummy app doubles as a demo. The seeds build **Demo Co**: two years of books with a chart of accounts, GST, a department dimension, a couple of hundred posted entries and a few drafts, the first half of last year closed, and a bank statement to reconcile for the operating account. `bin/setup` runs them when it creates the database; `bin/setup --reset` drops the databases and rebuilds them, and `bin/rails app:db:seed` seeds an existing one. With `bin/dev` running, open `/session/new` and choose "Open the demo books"; that seeds Demo Co first if it isn't there yet. Seeding again leaves the books alone, apart from adding the new year's periods once the year turns.

The demo code lives in the dummy app under the `Demo::` namespace (`spec/dummy/app/*/demo`) and has its own specs in `spec/dummy/spec`:

```bash
docker compose exec rails bash -lc 'cd spec/dummy && RAILS_ENV=test bundle exec rspec'
```

The engine's specs boot the dummy app without the demo, so they never depend on it.

## Integration into a Host Application

Requirements: Ruby 3.3+, Rails 8.1, PostgreSQL, and (for the engine's pages) tailwindcss-rails 4 and importmap-rails, as a new Rails app with `--css=tailwind` has.

```ruby
# Gemfile
gem "tudla_accounting", github: "tibomogul/tudla_accounting"  # or path: "../tudla_accounting"
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
  config.current_organization = ->(controller) { controller.send(:current_organization) }
  config.current_actor = ->(controller) { controller.send(:current_user) } # recorded on audit events (optional)

  config.base_currency = "USD"
  config.time_zone = "UTC"                # zone PeriodCreator builds periods in; plain Dates are read in it
  # Retained earnings, receivables, payables and exchange gains are accounts marked by
  # role in each organization's chart (see account roles), not settings.
  config.cash_account_codes = %w[1010]    # the cash flow statement's default cash, with sub-accounts;
  # or a callable given the organization, for books whose charts differ (a bookkeeper's clients):
  # config.cash_account_codes = ->(organization) { organization.cash_account_codes }
  config.organization_label = ->(organization) { organization.name } # names it in errors (default: class and id)

  # Journal numbers, given when entries are posted (see numbers and references)
  config.entry_number_series = :organization # or :financial_year, or ->(entry) { "series" }
  config.entry_number_format = "#%{number}"  # or "JE-%{series}-%<number>05d", or ->(entry) { ... }

  # Attachments (with Active Storage): what may be attached, by identified type, and how big
  config.attachment_content_types += %w[application/zip]
  config.attachment_max_size = 20.megabytes

  # Receivables and payables (carrying amounts). Off until the organization has an
  # account marked receivable or payable: entries still post normally, but no
  # carrying amounts are tracked.
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

  # Foreign exchange: where missing rates come from (gains and losses go to the accounts
  # marked unrealized_fx_gain and realized_fx_gain)
  config.forex_rate_provider = TudlaAccounting::RbaForexRateProvider.new # or any ->(from:, to:, date:) { rate }
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
