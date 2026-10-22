# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- **Breaking:** the general ledger CSV has new columns: `Entry no.` and `Reference` after the date, and `Description` (the line's) after the entry.
- Entries are shown with their numbers across the pages (ledgers, banking, payments applied) and on the audit trail.
- **Breaking:** the accounts the books treat specially are marked by role on each organization's own accounts (`Account#role`: `receivable`, `payable`, `retained_earnings`, `unrealized_fx_gain`, `realized_fx_gain`), instead of named by code in the settings, so organizations' charts can differ (a bookkeeper's clients) and accounts can be renumbered. Set a role in the account form, with a `Role` column in the chart of accounts import, with `role:` in `AccountsCreator` (either refuses a role given to more than one of its accounts), or with `AccountRoleAssigner.save(account, role)`; `Account.for_role(organization, role)` finds it. Each role needs a suitable category. Roles change only through `AccountRoleAssigner` (`save`, or `save!` to raise), which the form, the import and `AccountsCreator` use; it moves a role from the account holding it, and a plain `account.update(role:)` is refused. In the form, only those with the `:administer` permission can change a role. Receivables and payables stay on an account once it, or an account beneath it, has posted lines (its open items would be left behind), and can't be given to such an account, whose lines opened nothing owed; either way, opening balances and drafts don't count.
- Marking the retained earnings account, moving it or taking it off rebuilds the organization's balances in the same transaction, so the earlier years' profit is carried where it now belongs (a client taken on mid-stream). `AccountRoleAssigner.batch(organization) { |assigner| ... }` makes several changes with one rebuild, all or nothing: if one is refused, none is made. Retained earnings can't change while a period after the first year is closed (reopen them first), so closed periods keep the balances they were closed with.
- Every rebuild's `balances.rebuilt` audit event now lists the accounts it corrected (`accounts`).
- Revaluation needs an unrealized gains account only when there's something to revalue.
- Errors about a missing account name the organization, through the new `organization_label` setting (default: class and id).

### Removed
- **Breaking:** the `receivable_account_code`, `payable_account_code`, `retained_earnings_account_code`, `unrealized_fx_gain_account_code` and `realized_fx_gain_account_code` settings: mark the accounts' roles instead (in your chart templates, `AccountsCreator` data and import files). Setting one raises `TudlaAccounting::ConfigurationError` saying which role to mark. There's no upgrade path from 0.2.0, which was never published.

### Added
- Journal numbers: posting gives an entry the next number of its series (`Entry#number`, shown by `number_label`), with no gaps, since drafts have none and posted entries are never deleted. The `entry_number_series` setting numbers entries in one run per organization (the default), per financial year, or by a callable; `entry_number_format` shows them (a format string or a callable; `#42` by default). Either can change later without renumbering what is posted. Entries posted before the upgrade are numbered in the order they were created.
- `Entry#reference` for a cheque number, a supplier's invoice number and the like: in the entry form, `create_from_ruby_hash(reference:)`, kept on reversals. The entries page searches references and numbers too.
- A description on each entry line (`Detail#description`): a field under each line's account in the entry form, `description:` on a line in `create_from_ruby_hash`, kept on reversals, shown on the entry and in the ledgers, and searched on the entries page. An entry made from a bank statement line under other particulars keeps the statement's description on the bank line.
- Attachments on entries, with Active Storage in the host app: `Entry#add_attachments!` attaches receipts and documents to drafts and posted entries, checked against the `attachment_content_types` and `attachment_max_size` settings, and `Entry#remove_attachment!` removes them (from a posted entry only with a reason). Both are on the audit trail with the file's checksum (`entry.attachment_added`, `entry.attachment_removed`). The entry page lists, uploads and removes them (a posted entry's only with `:administer`), serving files through the engine so its permissions apply; the entries list marks entries with files. The install generator says how to set up Active Storage.
- Inactive accounts: `Account#deactivate!` (the account page's Make inactive) stops offering an account and those beneath it for new entries, keeping their history, balances and reports; `reactivate!` offers one again. Refused for an account holding a role, taking an active tax code's tax, or with receivables or payables still open (`deactivation_blocker`). The entry form, banking forms and account choices leave inactive accounts out (filters mark them), and `Entry.create_from_ruby_hash` and `BankReconciler#create_entry!` refuse them. Recorded as `account.deactivated` and `account.reactivated`.
- Comparative statements: the balance sheet and profit and loss compare the period chosen with the previous one or the same one a year earlier (with the change and percentage change), or show each month of the year (with the year's total in profit and loss), through the pages' Compare with choice or `Reports::Comparison`.
- Reports download as Excel workbooks too (`.xlsx`, `Reports::Table#to_xlsx`) when the host app bundles the optional `caxlsx` gem (`TudlaAccounting.xlsx?`), and print cleanly (Print or save as PDF): no navigation or forms, light colours, every column of a wide table, landscape for wide comparisons.
- Every report downloads as CSV (each page's Download CSV link, or its path with `.csv`), as shown on the page, comparisons included; `Reports::Tables` lays each one out as a `Reports::Table`. Text a spreadsheet would run as a formula is written with a leading apostrophe, in the general ledger's CSV too.
- Bank rules: record unmatched statement lines by rules (description contains, direction, amount range, bank account → account, tax code, dimension values, particulars), suggested on the banking page, one line or all at once, and started from a line. `BankReconciler#create_entry!` takes `tax_code:` and `dimension_values:`.
- Budgets (`Budget`, `BudgetLine`): named plans for a year, an amount per income and expense account per month, one of them the year's main budget. Started blank, from a year's actual results changed by a percentage, or from another budget; entered on a grid that keeps totals and spreads a year's amount over the months; downloaded and uploaded as CSV or Excel. On the audit trail as `budget.created`, `budget.updated` and `budget.deleted`.
- Tax returns (`TaxReturnForm`, `TaxReturnBox`, `TaxReturnBoxPart`, `TaxReturnCalculator`): forms of boxes, each adding or subtracting tax codes' net amounts, tax or gross amounts, accounts' movement and earlier boxes, optionally in whole units; templates for Australia's BAS and the UK VAT return; set up under Setup → Tax returns and shown, box by box with their parts, on the Tax return report (CSV and Excel too). Tax codes and accounts a return uses can't be deleted.
- Refunds: paying back what is left of a customer's payment or credit note, or recording a supplier's refund of theirs, as a payment of kind `refund` or `supplier_refund` (`Payment.record!(refund_of:)`), from the payment's, credit note's or contact's page, or through the API (`POST /payments` with `refund_of`). Refunds are listed with the payments (the payments CSV has a `Kind` column at the end), and a receipt lists what was refunded of it.
- Applying a leftover credit from the payment's or credit note's page and the contact's page, not only the entry's, and through the API (`POST /payments/:id/apply`, `POST /documents/:id/apply`).
- Dimensions on invoice and bill lines: a column per dimension in the form, `dimensions` on each line in the API, shown on the document's page (not on the printed document). Approving it tags each line's posting, so profit and loss by dimension includes sales and purchases; a credit note copies its lines' values from what it credits.
- Files on invoices, bills and credit notes (the supplier's PDF on a bill, say), as on entries, on their pages and through the API (`attachments` in an entry's or document's JSON; `POST` and `GET .../attachments`). Attaching and removing files is shared by entries and documents (`Attachable`), and is on the audit trail as `document.attachment_added` and `document.attachment_removed` too.
- Overdue reminders: with `reminder_days` set, customers of overdue invoices are emailed a reminder on those days after the due date, each once, from Sales → Reminders due or by `SendRemindersJob` (which the host schedules), using `ReminderRunner`; and any overdue invoice can be reminded by hand from its page.
- Emailing statements of account (one, or every one the statements page shows, naming those with no email address) and payments' receipts and payment notices (from the payment's page, or as the payment is recorded), as invoices are emailed. A contact's page lists their statements' emails.
- Recording a payment with nothing to apply it to (no open invoices or bills) no longer fails.
- Something not found asked for as a PDF or CSV (another organization's invoice, say) answers 404 instead of failing.
- Emailing invoices and credit notes from their pages (`Delivery`, `DeliveryJob`, `DocumentMailer`, `EmailDraft`): the email starts from a template (`document_email_templates`) to the contact, can be changed, and is sent in the background through the host's ActionMailer setup with the PDF attached, from `document_mail_from` and replying to `document_mail_reply_to`; or through the host's own mailer (`document_mailer`). Each email is recorded as queued, sent or failed (with the error, to send again), listed on the document's page, marked on the Sales list, and on the audit trail as `email.sent` and `email.failed`.
- The engine's `ApplicationMailer` no longer sets a From of its own (it was the generator's placeholder): the host's ActionMailer default applies.
- PDFs of invoices, bills and credit notes, statements of account, and payments (a receipt, or a payment notice), made in headless Chrome from the layouts the pages print when the host bundles the optional `ferrum` gem (`TudlaAccounting.pdf?`, `PdfMaker`, Download PDF on their pages). Settings: `pdf_browser_options`, `pdf_paper`, `pdf_stylesheet`. Statements are headed by `document_header` too, and a payment's page shows its receipt or payment notice, ready to print.
- A JSON API at `api/v1` under the engine's path (see `API.md`), reached with an API token. Reading (`read`): the organization, accounts, entries, contacts, invoices and bills, payments, tax codes, periods and the reports, paged, with filters and `updated_since` for syncing. Recording: entries, contacts, and invoices and bills as drafts (`record`); posting and reversing entries, approving and voiding invoices and bills, recording and voiding payments (`post`). Creates take an `Idempotency-Key` header; documents and payments keep it (`idempotency_key`), as entries do. Each token may make `api_rate_limit` requests a minute (300 by default), counted in `api_rate_limit_store` (`Rails.cache` by default).
- API tokens (`ApiToken`, Setup → API tokens): issued with permissions and an optional expiry, the secret shown once and kept only as a digest, last use noted, revoked rather than deleted; a token acts as itself on the audit trail. On the audit trail as `api_token.created` and `api_token.revoked`.
- Payments (`Payment`, Record payment, the Payments received and Payments made pages): money received or paid through a bank or cash account, posted straight away and applied to the contact's invoices or bills as chosen, the rest kept as a credit; voided by reversing their entry. A bank statement line can be recorded as a payment of an open invoice or bill, and is matched to it. On the audit trail as `payment.recorded` and `payment.voided`.
- Invoices, bills and credit notes (`Document`, the Sales and Purchases pages): drafted line by line with quantities, prices, accounts and tax codes, approved (numbered per kind with `document_number_format`, and posted, opening the contact's receivable or payable, or a credit applied to the document it credits), voided by reversing their entry, and printed or saved as PDF headed by `document_header`. Listed by status with what is still owed, and downloaded as CSV. On the audit trail as `document.created`, `.updated`, `.deleted`, `.approved` and `.voided`.
- Contacts (`Contact`, the Contacts page): customers and suppliers with their details, payment terms and default account and tax code, each showing what they owe or are owed, searched, downloaded as CSV and imported from CSV or Excel (`ContactImporter`). On the audit trail as `contact.created`, `contact.updated` and `contact.deleted`.
- Filed tax returns (`FiledTaxReturn`): Mark as filed keeps a return's figures for its months, shown later beside what the books give now, box by box; returns of a form can't overlap unless one is withdrawn with a reason. On the audit trail as `tax_return.filed` and `tax_return.withdrawn`.
- Customer and supplier statements (`PartyStatement`, the Statements page, linked from the aging reports): the opening balance, the invoices, bills, payments, credit notes, refunds and reversals in a run of days with the running balance, and the closing balance with its aging; or the open items at the end. They print on their own for sending and download as CSV or Excel; All customers (or suppliers) prints every statement with something to send, one to a page. `AgingReportGenerator` takes `party:` to age one party's items.
- Budget vs actual on the profit and loss (Compare with a budget, `Reports::BudgetComparison`): actual, budget, variance and percentage for the period, and for a month the year to date too, each variance marked favourable or unfavourable; in the CSV and Excel downloads as well. The demo has a budget for this year.
- A tax code that recurring entries or bank rules use can't be deleted (it was refused by the database, not explained).
- Bank statements import from OFX and QFX files (OFX 1.x SGML and 2.x XML, bank and credit card) and ISO 20022 CAMT.053 statements as well as CSV, told apart by their contents, with the file's closing balance on its last line. `BankStatementImporter.call` now also returns the `format` it read.
- Recurring entries: templates of lines with a schedule (every N weeks, months or years, on a day or the last day, until a date or a number of entries), making drafts or posted entries, optionally reversed the next month. `RecurringEntryRunner` (and `RecurringEntriesJob`, for the host to schedule) makes the entries due, catching up, once each; problems are kept on the template and shown. A Recurring entries page, Make recurring on an entry, and audit events.
- `Entry.build_from_ruby_hash`: the entry `create_from_ruby_hash` would create, unsaved.
- Auto-reversing entries: an entry with `reverse_on` (the form's "Reverse automatically on", or `create_from_ruby_hash(reverse_on:)`) posts its reversal on that date when it is posted, in the same transaction. Refused for invoices, bills, payments and credits, and when no financial year covers the date.
- `USAGE.md`: setting up an organization's books step by step, in the pages or from the console and rake tasks. Its examples run in the suite.
- The dashboard warns, and `tudla_accounting:balances:check` prints a warning (without failing), when an organization with accounts has none marked retained earnings, receivable or payable while `carrying_amount_sources` records that side, or unrealized or realized exchange gains once one of its accounts is held in another currency: without them nothing is tracked or carried, and nothing else says so.
- `cash_account_codes` can be a callable given the organization; `TudlaAccounting.configuration.cash_account_codes_for(organization)` reads it.

## [0.2.0] - 2026-10-06

Tagged but never published. Later versions don't support upgrading from it (or from 0.1.0): until a release is published, start from a fresh install.

### Added
- Indirect-method cash flow statement (`Reports::CashFlow.new(..., method: :indirect)`, or the page's Method choice): net profit plus each balance-sheet account's change, by activity, matching the direct method's totals.
- Entries can be created from a foreign-currency bank account's statement lines, converted at a rate given or the rate provider's rate for the day, with the statement amount as the bank line's foreign amount.
- Cash-basis tax summary: tax on invoices, bills and taxed credit notes counts as they are settled (each allocation's share, reversed if taken off); entries with no receivable or payable count when posted. Choose it on the page, per call (`basis: :cash`) or with the `tax_basis` setting.
- Lines with a foreign amount can be taxed: the tax is worked out on the converted amount and posted in the organization's currency (an inclusive line's foreign amount is split too). A tax account held in another currency is refused.

### Fixed
- `Entry.create_from_ruby_hash` stored a foreign amount given as a decrease (`EUR -55.00`) as a negative number; it is now a magnitude, like the line's amount.

## [0.1.0] - 2026-10-06

First release.

### Books
- Chart of accounts as a tree, with contra accounts, foreign-currency accounts and a cash flow activity per account; load it from CSV or Excel with opening balances, or enter opening balances on a form.
- Financial years split into months (calendar or fiscal), closed and reopened in order with a reason; nothing posts into a closed period.
- Journal entries as drafts, posted into the month of their date and reversed (never edited) once posted; `Entry.create_from_ruby_hash` with idempotency keys, and entries from host-app records.
- Balances kept per account and period with automatic year-end carry-forward to retained earnings; a balance check and rebuild from the posted entries.

### Receivables and payables
- Invoices, bills, payments, disbursements, credit notes, supplier credits and refunds by configurable source class; credits applied to invoices and bills through allocations (one payment across many invoices, oldest first, taken off again), with aging reports.
- Foreign currency: realized exchange differences on settlement, period-end revaluation with automatic reversal, and exchange rates from a configurable provider (Reserve Bank of Australia included).

### Tax, banking and dimensions
- Tax codes for sales and purchases, taxed lines (tax added or split out) from the API and the entry form, and a tax summary.
- Bank statement CSV import, suggested and manual matching, entries for bank-only lines, and a reconciliation summary.
- Reporting dimensions (department, project...) tagged on entry lines, with profit and loss by dimension.

### Reports
- Balance sheet, profit and loss, trial balance, general ledger (with CSV), cash flow (direct method), aging, tax summary and profit and loss by dimension.

### Integrity and integration
- Unique keys and checks in the database; on PostgreSQL, triggers that refuse changes to posted entries, posting into closed periods and edits to the audit trail (reinstalled whenever a schema is loaded).
- An audit trail of everything done to the books, with an activity page.
- Hooks for host apps: `current_organization`, `current_actor`, `authorize` (read/record/post/administer), `TudlaAccounting.subscribe` events after commit, and `rails generate tudla_accounting:install`.
- Web pages for all of the above, styled with Tailwind CSS v4 and following the host's light/dark theme.
- Set-based posting and batched balance reads for large ledgers; `perf/benchmark.rb` to measure them.

[Unreleased]: https://github.com/tibomogul/tudla_accounting/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/tibomogul/tudla_accounting/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/tibomogul/tudla_accounting/releases/tag/v0.1.0
