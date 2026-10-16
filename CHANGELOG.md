# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- **Breaking:** the accounts the books treat specially are marked by role on each organization's own accounts (`Account#role`: `receivable`, `payable`, `retained_earnings`, `unrealized_fx_gain`, `realized_fx_gain`), instead of named by code in the settings, so organizations' charts can differ (a bookkeeper's clients) and accounts can be renumbered. Set a role in the account form, with a `Role` column in the chart of accounts import, with `role:` in `AccountsCreator` (either refuses a role given to more than one of its accounts), or with `AccountRoleAssigner.save(account, role)`; `Account.for_role(organization, role)` finds it. Each role needs a suitable category. Roles change only through `AccountRoleAssigner` (`save`, or `save!` to raise), which the form, the import and `AccountsCreator` use; it moves a role from the account holding it, and a plain `account.update(role:)` is refused. In the form, only those with the `:administer` permission can change a role. Receivables and payables stay on an account once it, or an account beneath it, has posted lines (its open items would be left behind), and can't be given to such an account, whose lines opened nothing owed; either way, opening balances and drafts don't count.
- Marking the retained earnings account, moving it or taking it off rebuilds the organization's balances in the same transaction, so the earlier years' profit is carried where it now belongs (a client taken on mid-stream). `AccountRoleAssigner.batch(organization) { |assigner| ... }` makes several changes with one rebuild. Retained earnings can't change while a period after the first year is closed (reopen them first), so closed periods keep the balances they were closed with.
- Every rebuild's `balances.rebuilt` audit event now lists the accounts it corrected (`accounts`).
- Revaluation needs an unrealized gains account only when there's something to revalue.
- Errors about a missing account name the organization, through the new `organization_label` setting (default: class and id).

### Removed
- **Breaking:** the `receivable_account_code`, `payable_account_code`, `retained_earnings_account_code`, `unrealized_fx_gain_account_code` and `realized_fx_gain_account_code` settings: mark the accounts' roles instead (in your chart templates, `AccountsCreator` data and import files). Setting one raises `TudlaAccounting::ConfigurationError` saying which role to mark. There's no upgrade path from 0.2.0, which was never published.

### Added
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
