# Design review, November 2026

A critique of the engine's design, its separation from the host application and its configurability, written on 7 November 2026 at `a7b8478`, after the Australian work (BAS, no-ABN withholding, TPAR). Nothing was changed for it. The checklist at the end lists what must be done.

## Summary

The accounting core is solid and carefully protected. The weakest parts are three:

- **Country-specific rules are mixed into the core.** Philippine and Australian rules sit in the core models, schema, settings and reports page, with nothing marking which country a feature belongs to.
- **Some settings that should be per organization are global.** A few of them change the host app's own behaviour too.
- **The UI forces one front-end stack on the host.** It requires Tailwind and importmap.

Some of the recent Australian work made the first problem worse.

## What's strong

- **The ledger is protected.** PostgreSQL triggers in `lib/tudla_accounting/database_protection.rb` refuse changes to posted entries, posting into closed periods, and changes to the audit trail. Posted data is never edited: corrections are reversals and opposite rows, and `WithheldTax` keeps its history the same way.
- **Money is handled consistently.** Typed amounts all go through `AmountParser`, and pages and files are written through `MoneyFormatter` and the `tc_money` helpers. Balances roll up through both the account tree and the period tree, and `BalanceRebuilder` can check them.
- **The API is careful.** Creating requests take an idempotency key, permissions are declared per action, rate limits apply, and every endpoint is documented in `API.md`.
- **The demo is properly isolated.** `spec/integration/demo_isolation_spec.rb` boots the app in a separate process to prove the engine loads no demo code. That's unusually rigorous.
- **The test discipline is real.** Line coverage is 100%, `USAGE.md` is run as a test, and there are concurrency specs using real row locks.

## Problems, most important first

### 1. Country-specific rules live in the core, with nothing to switch them on or off

About 200 references to BIR, the ATO, ABN, TIN, SLSP, 2307, SAWT and QAP are spread through `app/` — models, controllers, the reports page and the settings.

- **Australian books are offered Philippine forms.** On the dev server, Demo Co's Reports page lists "Certificates to suppliers (2307)", the SAWT, the QAP and the BIR summary lists. The cause is that `reports/index.html.erb` shows the Philippine withholding reports whenever *any* withholding code exists. Adding NOABN to the demo created that situation.
- **Core tables carry one country's fields.** `Contact#taxable_payments` (Australia's TPAR), `TaxCode#purchase_type` (Philippines' SLSP) and the `withholding_agent` setting's `tin`, `zip` and `signatory_tin` (BIR 2307) are all in the general schema. Every host pays for them.
- **Some Philippine assumptions are built into the core.** Months are grouped into filing quarters through `FilingQuarters`, and `BspRatesJob` fetches rates from the Philippine central bank.

The core already has general building blocks: tax return templates, withholding codes and table reports. What's missing is a country (jurisdiction) setting per organization, so features and reports appear only where they apply. The alternative would be optional country add-ons that register their own reports, templates and contact fields. Without one of these, each country added makes every other country's books a little worse.

### 2. Settings that need to differ by organization are global

The configuration is one object for the whole process.

- **Some settings can vary by organization:** `document_header`, `tax_registration`, `number_format` and `cash_account_codes` accept a callable that's given the organization.
- **Others can't:**
  - **`time_zone`** is used in 45 places, including period boundaries, "today" and the monthly SLSP. A host with Sydney books and Manila books has to choose one zone, so postings near midnight land in the wrong day, month or year for the other. The dev server shows this: Demo Co and Demo Pilipinas share one zone.
  - **`rounding`, `tax_basis`, `pdf_paper`, `reminder_days` and the email templates** apply to every organization.
  - **`base_currency`** is meant only as a fallback when there's no organization, but `carrying_amount_processor.rb:212` compares a bank account's currency with it rather than with the organization's own currency. That's a latent bug: a PHP organization on a host set to USD would get the logic backwards. It sits in dead code, though — see 5.
- **The configuration is inconsistent about which settings take a callable,** so a host can't predict which ones it can vary.

### 3. The engine changes the host app's global settings

- **It overwrites the host's Money settings.** `apply_money_settings!` sets the default currency, rounding mode and locale backend for the whole app, so the host's own Money code changes when the engine is installed.
- **It reads the test factories folder.** `engine.rb` adds `spec/factories` to FactoryBot's paths in any app that loads FactoryBot. That folder isn't shipped in the gem.

### 4. The UI requires a particular front-end stack

- **Tailwind and importmap are hard dependencies.** `tailwindcss-rails` and `importmap-rails` are required by the gem, the engine's CSS has to be compiled into the host's own Tailwind build, and the layout links the host's `tailwind.css`.
- **Some hosts can't use the pages easily.** That includes apps using jsbundling or Vite, apps without Tailwind, and API-only apps. An API-only host still has to install both gems.
- **The theme follows the demo's convention.** Theme sync reads `localStorage('theme')`, which is the dummy app's DaisyUI habit.
- **PDFs need headless Chrome,** through the ferrum gem.

A precompiled engine stylesheet, plus a core gem separate from the UI, would remove this lock-in.

### 5. Two ways to track what's owed, and some dead code

- **Two ways to track receivables and payables:**
  - an older path where the host registers its own records (`register_entry_source`, `carrying_amount_sources`, `due_date_method`, `related_party_method`);
  - the newer engine path using Contacts, Documents and Payments.

  Both work, but a newcomer can't tell which to use, and each new feature (withholding, tax returns, TPAR) supports only the newer one.
- **`BankAccountBalance` looks dead.** Nothing in `app/` creates one, and nothing shows it. It's still updated during posting and contains the currency bug from point 2.

### 6. Reversals are recognised by English text

A reversal is identified by its particulars starting with `"Reversal of: "` (see `Entry::REVERSAL_PREFIX`, and four queries that match on it).

- **There's no flag column** that marks an entry as a reversal.
- **It blocks translation.** The text can't be translated without breaking the queries.
- **It's getting worse.** The `account_credits` tax return source added another dependency on this string.

### 7. No translation layer

The views use no `t(...)` calls and there are no locale files. All page text, email text and PDF wording is English and written directly in templates. Overriding the views is the only way to change wording, which is costly, and that wording keeps changing as forms change.

### 8. Tenant separation depends on convention

- **How it works now:** each controller wraps its lookups in `organization_scope(...)`, about 250 times. A dozen unscoped queries are safe only because they start from records that were already scoped. Every engine table links to the organization polymorphically, with no foreign key.
- **What protects it:** discipline, plus about 35 specs that try other organizations' data. The database itself doesn't refuse cross-organization access.
- **The risk:** one missed scope in a new controller would leak another organization's data.

Making the scoped lookups the default, or using PostgreSQL row-level security, would make the database enforce it.

### 9. 100% coverage proves less than it seems

- **Tests can't confirm the tax rules.** They check the code does what was designed. They can't check the BIR or ATO rules, which came mostly from search summaries. The README's "what to confirm" lists are honest about this, and they matter more than the coverage number.
- **Many specs compare exact page text,** so wording changes break them and mean a lot of spec maintenance.

## The recent Australian work, rechecked

- **The reports page leaks Philippine reports** to Australian books, as described in point 1. The NOABN work set it off.
- **`Reports::TaxablePayments` has an N+1 query problem.** It calls `payment.applications` for each payment, which is a few queries each. CLAUDE.md says a page's query count shouldn't grow with the number of rows, so this needs batching.
- **The TPAR flag is current, not historical.** Unticking a contact removes them from years already lodged.
- **TPAR converts GST at the wrong rate for foreign bills.** It uses the payment's exchange rate, not the bill's. This doesn't matter in AUD books, but it isn't what the ledger holds.
- **TPAR doesn't deduct supplier refunds or credit notes.**
- **The "last financial year" default can pick the wrong months.** In `month_range(last_year:)`, it assumes each month sits directly under its year. If periods had quarters, it would pick the last quarter instead. `year_to_date` has the same assumption already.
- **`WithholdingCode#split_cash` can give a base larger than the amount due** when matching a bank line that pays more than the bill.
- **Pay runs can't skip withholding for one supplier,** and a no-ABN code applies even to small payments.
- **Withholding checks show differences by design.** Payments to the tax office always show as a difference against the account, which is noise in typical books.
- **Unconfirmed tax rules stay unconfirmed.** That covers the no-ABN rate, the TPAR fields, the deadlines and who has to lodge. They're documented as such, but still unconfirmed.

## Suggested order

1. **Add a country (jurisdiction) setting per organization,** used to show or hide country reports, templates and fields. That fixes the reports page leak straight away. Then move the Philippine and Australian code into separate modules or optional add-ons.
2. **Allow per-organization values for `time_zone`, `rounding` and `tax_basis`.** Stop changing the host's Money settings, and remove `BankAccountBalance`.
3. **Add a `reversal_of_id` column** to entries and stop matching on text.
4. **Split the gem into a core gem and a UI gem,** with the UI's stylesheet precompiled.
5. **Add a translation layer,** starting with the text used in emails and PDFs.
6. **Decide whether the older host-records path for receivables and payables stays,** and document it as secondary if it does.
7. **Fix the TPAR N+1 queries.**

Items 1 and 3 come first. Item 1 decides how far the engine can grow beyond two countries, and item 3 is cheap now and harder once there's more data.

## Checklist

Grouped in the suggested order. Items marked **(decide)** need a decision before any code.

### Now: small fixes

- [x] Show the Philippine withholding reports (2307, QAP, SAWT, BIR summary lists, SLSP) only to books they apply to, not whenever any withholding code exists. Done with a `country` setting (a code or a callable given the organization; every country's reports when nil), the first step of the jurisdiction work below.
- [x] Batch `Reports::TaxablePayments`' queries so the count doesn't grow with payments, and add it to `perf/benchmark.rb` (`Payment.applications_for`; 13 queries for 100 payments). The benchmark never paid a bill, so it now pays the bills it approves for the withholding timing.
- [x] Convert TPAR's GST at the bill's exchange rate, not the payment's.
- [x] Deduct supplier refunds and credit notes from TPAR's gross and GST. A refund is taken off with the GST of the credit it paid back; a credit note applied to a bill already lowers what the payment paid.
- [x] Make `ReportPeriods#month_range(last_year:)` and `year_to_date` find the year by walking up the period tree, with a spec for books with quarters (they compare `root_id`).
- [x] ~~Cap `WithholdingCode#split_cash`'s base at the amount due when matching a bank line.~~ Not a bug on recheck: tax withheld on payment is on the whole payment, so cash beyond the bill is still a payment to the supplier and taxed; it stays on them as an unapplied credit, as `Payment.record!` allows.

- [x] Load the payments API list's applications for the whole page (`GET /payments` ran six queries a payment, `POST /pay_runs` the same for each payment made), with a query-count spec.

### 1. Jurisdiction

- [x] **(decide)** A jurisdiction setting per organization, or optional country add-ons that register their own pieces — or the first as a step towards the second. Decided: the setting first, as a step towards add-ons.
- [x] Add the jurisdiction to the organization (a column or a per-organization callable). The `country` setting, a code or a callable.
- [x] Have the reports index, tax return templates, withholding code templates and contact form fields read it. `Jurisdictions` lists each country's features; the report pages and API reports are not found for another country, templates carry their country, and the TPAR and "Bought as" fields show only for their country or where already set.
- [ ] Move the Philippine pieces (2307, QAP, SAWT, SLSP, `FilingQuarters`, `BspRatesJob`, books of accounts, `TaxCode#purchase_type`, the `withholding_agent` fields) behind it.
- [ ] Move the Australian pieces (BAS template, NOABN code, payee list and payment summaries, TPAR, `Contact#taxable_payments`) behind it.
- [ ] **(decide)** Keep the TPAR flag as it is, or record it per payment or per year so lodged years don't change.

### 2. Configuration and the host boundary

- [x] Make `time_zone` per organization, and use it for period boundaries, "today" and the SLSP months. `TudlaAccounting.zone(organization)`; `PeriodCreator` refuses a new year if the zone changed under existing periods.
- [x] Make `rounding`, `tax_basis`, `pdf_paper`, `reminder_days` and the email templates per organization. All five joined `PER_ORGANIZATION`; this also fixed `pdf_paper = :Letter`, which never worked.
- [x] Make every setting accept either a value or a callable given the organization, consistently, and document which is which. `Configuration::PER_ORGANIZATION` and `for_organization`; the README lists them. Settings made per organization later join the list.
- [x] Stop `apply_money_settings!` overwriting the host's MoneyRails defaults; pass the currency and rounding explicitly instead. The dummy app now sets its own different defaults (yen, rounding down, the i18n backend), so the suite checks the engine doesn't depend on them.
- [x] Stop `engine.rb` adding `spec/factories` to FactoryBot's paths in host apps. The dummy app adds them now.
- [x] Remove `BankAccountBalance` and its posting (taking the `base_currency` comparison with it), with a migration dropping the table.

### 3. Reversals

- [x] Add `reversal_of_id` to entries, with a migration filling it from the existing "Reversal of: " particulars. Unique, so an entry is reversed once in the database too.
- [x] Change `posted_reversal`, `account_credits`, the realized gain lookup and the SLSP to use the column, and drop the LIKE queries. The cash-basis tax summary used it too. The realized gain lookup goes through `Entry#reversal`, which now reads the column.
- [x] Mark realized exchange differences (and revaluations) by a column too. `Entry#kind` (`realized_exchange`, `revaluation`, `revaluation_reversal`); a revaluation run again after an account was renamed no longer posts twice. `Entry#realized_exchange?` and `AllocationBackfill` read it; the particulars are only wording now.

### 4. Front-end lock-in

- [ ] **(decide)** Split into a core gem and a UI gem, or keep one gem with the UI optional.
- [ ] Ship a precompiled engine stylesheet, so the host doesn't need Tailwind.
- [ ] Make importmap optional for hosts using jsbundling or Vite.
- [ ] Make the theme sync configurable, instead of assuming `localStorage('theme')`.
- [ ] Make the PDF renderer replaceable, so headless Chrome isn't required.

### 5. Translation

- [ ] Add `config/locales/en.yml` and move email and PDF text into it first.
- [ ] Move page text into it, view by view.
- [ ] Let specs that compare exact page text read from the locale file where that makes them less brittle.

### 6. Receivables and payables

- [ ] **(decide)** Keep, deprecate or remove the host-records path (`register_entry_source`, `carrying_amount_sources`, `due_date_method`, `related_party_method`).
- [ ] Document the outcome in the README, naming Contacts, Documents and Payments as the main path.

### 7. Tenancy

- [x] Add a check that fails when an engine controller looks up a model without `organization_scope`. `spec/integration/tenancy_spec.rb`, over controllers, views and helpers; 31 lookups were scoped or explained, and the line editor's tax codes were tightened.
- [ ] **(decide)** Enforce tenancy in the database with PostgreSQL row-level security, or with scoped lookups by default.

### Withholding, smaller items

- [x] Let a pay run skip withholding for one supplier. A box beside the supplier; `skip_withholding` in `PayRun.call` and the API.
- [ ] **(decide)** Whether the no-ABN code should skip small payments, once the ATO threshold rules are confirmed.
- [x] Let the withholding checks show payments to the tax office as expected, rather than as a difference. A "Paid to the tax authority" (or "Claimed against tax due") figure; reversals of withholding entries don't count in it.

### Not code: confirm with an adviser or the tax office

- [ ] The ATO no-ABN rate, the TPAR fields, deadlines and who has to lodge (README, "what to confirm").
- [ ] The BIR items still listed as unconfirmed in the README.
