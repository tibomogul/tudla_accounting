# TudlaAccounting

A double-entry general ledger for Rails apps, packaged as a mountable **Rails 8.1 engine**. Add it to a host app to get a chart of accounts, balanced journal entries, and account balances that roll up through account and period hierarchies. It can also track receivables and payables, including in foreign currencies, and supports multiple organizations.

## What it does

### Chart of accounts
`TudlaAccounting::Account` belongs to an organization and has a `code`, a `name`, and a category: `asset`, `liability`, `equity`, `income` or `expense`. Accounts form a tree, e.g. *1100 Accounts Receivable > 1105 AR – EUR customers*. A child must share its parent's category. An account can name a **contra account**, which flips its normal side, e.g. accumulated depreciation against an asset. The receivable and payable accounts are the totals of a sub-account for each currency: giving either role makes the one in the organization's currency (`1100-USD`, taking the account's own opening balance), and the first invoice, bill or payment in another currency makes that currency's (`1100-EUR`). Only an account without sub-accounts takes postings, since a parent holds what its sub-accounts add up to, in every period: a line on an account with sub-accounts is refused (`account.posting_blocker` says why), and so is a sub-account beneath an account with postings or an opening balance of its own, or holding a role other than receivables or payables (`sub_account_blocker`). A draft written before its account took sub-accounts can still be saved, but must move to one of them before it posts. `Account.postable` is the accounts without sub-accounts, and the forms offer only those wherever a line will post (entries, invoice and bill lines, recurring entries and invoices, payments and the pay run, bank rules and the banking page, a contact's default account and a tax code's account), keeping one a record names already, marked "(has sub-accounts)"; parent, contra account and filter choices list every account. `Entry.create_from_ruby_hash`, `BankReconciler#create_entry!` and an invoice or bill line refuse an account with sub-accounts up front.

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

### Tax returns
`TudlaAccounting::TaxReturnForm` lays out a return you file (a BAS, a VAT return): its boxes (`TaxReturnBox`: label, name, order, and `whole_units` to drop the cents as the form asks), each the sum of its parts (`TaxReturnBoxPart`), added or subtracted:

- a tax code's net amount (`tax_code_base`), tax (`tax_code_tax`) or the two together (`tax_code_gross`), as the tax summary has them on the chosen basis;
- an account's movement in the months (`account`), its sub-accounts included, on its natural side, for wages, amounts withheld and the like that no tax code carries;
- an earlier box's figure (`box`), as reported, for totals such as 1A less 1B.

```ruby
bas = TudlaAccounting::TaxReturnForm.from_template!(organization, "au_bas") # or "uk_vat"; the boxes and their totals
bas.boxes.find_by!(label: "1A").parts.create!(source: "tax_code_tax", tax_code: gst)
bas.boxes.find_by!(label: "W1").parts.create!(source: "account", account: wages)
TudlaAccounting::TaxReturnCalculator.call(bas, from: july.from_date, thru: september.thru_date, basis: :cash)
# => { boxes: [#<Box box=G1 amount=... parts=[...]>, ...], basis:, from:, thru: }
```

A box uses only boxes above it, which then stay above it and can't be deleted while it does. A tax code or account a box uses can't be deleted. The templates (`TaxReturnTemplates`) lay out Australia's BAS (G1 to G11, 1A, 1B, W1, W2 and the net GST, in whole dollars) and the UK VAT return (boxes 1 to 9, 6 to 9 in whole pounds) with their totals; map your own tax codes and accounts to the rest, and check the box names against the current form before filing. Forms are set up under Setup → Tax returns (`:administer`), on the audit trail as `tax_return_form.created`, `.updated` (box changes included) and `.deleted`. The **Tax return** report shows a form's boxes for a run of months, each with the parts that fill it, and downloads as CSV or Excel; the tax summary links to it for the same months.

Once a return is lodged, **Mark as filed** on that report (or `FiledTaxReturn.file!(form, from:, thru:, basis:)`) keeps its figures, who filed it and when (`tax_return.filed` on the audit trail, with the figures). **Tax returns filed** lists them; each shows its figures as filed beside what the books give now (`FiledTaxReturn#comparison`, `#changes`), so a posting into its months since (or a change to the boxes) stands out, and suggests closing months still open. Returns of a form can't overlap; `withdraw!(reason:)` takes one back (`tax_return.withdrawn`) so a corrected return can be filed for the same months. A form with returns filed can't be deleted. Filing and withdrawing need `:administer`. The demo has a BAS mapped to its GST code and wages account, with last quarter's filed.

### Contacts
`TudlaAccounting::Contact` is a customer or supplier (`kind`: `customer`, `supplier` or `both`) with an email, phone, address, tax number, payment terms (`payment_terms_days`; `due_on(date)` gives a document's due date), the `currency` it is invoiced in (none for the organization's own; its new invoices, bills and payments start in it, the payment's when the books have a bank account in it) and a default account and tax code for its documents' lines. Contacts are the party documents are to or from, so the aging reports and statements work for them without host models; host apps whose own models are the related party (`related_party_method`) keep working as before. An inactive contact keeps its history; one that is owed or owes anything, or ever was, can't be deleted, and an account or tax code a contact defaults to can't be deleted either. Contacts are on the audit trail (`contact.created`, `contact.updated`, `contact.deleted`).

The **Contacts** page searches them by name, email or tax number, by side, with inactive ones on request, and downloads them as CSV; each contact's page shows their details and what they owe or are owed, by how overdue, with links to their statements. `ContactImporter.call(organization, path, ".csv")` (the page's Import, CSV or Excel) adds contacts from a file with the download's columns, updating those already there by name, all or nothing. Adding and changing contacts needs `:record`.

### Invoices, bills and credit notes
`TudlaAccounting::Document` is a sales invoice (`kind: "sales_invoice"`), a supplier's bill (`"bill"`) or a credit note against either (`"sales_credit"`, `"supplier_credit"`), to or from a contact, in the organization's currency or another (`currency`, with `exchange_rate`: how many of the organization's currency one unit is worth; left blank, the date's rate is looked up through `forex_rate_provider`). Its lines (`DocumentLine`) each have a description, quantity, unit price, account and optional tax code of the document's side; amounts exclude the tax, or include it with `tax_inclusive`, and the tax is rounded per line as an entry's is.

```ruby
invoice = TudlaAccounting::Document.create!(organization: organization, kind: "sales_invoice", contact: northwind,
                                            issued_on: Date.current, due_on: northwind.due_on(Date.current),
                                            lines_attributes: [ { description: "Consulting", quantity: 3, unit_price_cents: 150_00,
                                                                  account: sales, tax_code: gst } ])
invoice.approve!         # numbered INV-0001 and posted
invoice.amount_due       # what is still owed; payment_status: "unpaid", "part_paid" or "paid"
invoice.void!(on: Date.current, reason: "Issued twice") # reverses its entry
```

`approve!` numbers a draft in its kind's own run (`document_number_format`) and posts its entry, dated `issued_on`, with the document as its source: the total to the receivable (or payable) account's sub-account in its currency (`Account.for_role_in_currency!`), each line's net amount and tax to its accounts on the other side (the other way round for a credit note). A foreign document's amounts are converted at its rate line by line, the total being their sum, and the total goes to the sub-account in its currency (made as e.g. `1100-EUR` the first time) with its foreign amount, so revaluation and the aging report see it; `amount_due` is in its currency, `amount_due_in_base` in the organization's. A credit note is in the currency of what it credits. They are paid by payments in their currency (see [Payments](#payments)). An invoice or bill opens a receivable or payable for its contact, due on `due_on`; a credit note opens a credit, applied straight away to the invoice or bill it credits (`credited_document`) as far as that is still owed. The engine maps its own documents to these roles, whatever `carrying_amount_sources` says, so they work alongside a host's own sources. If the entry can't be posted (a closed period, say), nothing is numbered or posted. An approved document doesn't change: `void!` reverses its entry (refused while payments or credit notes are applied to it), and reversing the entry on its own page voids it too. Only drafts can be deleted. Documents are on the audit trail (`document.created`, `.updated`, `.deleted`, `.approved`, `.voided`), and keep their contacts, accounts and tax codes from being deleted.

The **Sales** and **Purchases** pages list them, searched by number, reference or contact, by kind and status (draft, awaiting payment, part paid, overdue, paid, void), with what is still owed (each in its currency; the total in the organization's), and download as CSV. The form fills in the contact's payment terms, default account and tax code, and adds up the lines as they're typed. Each document's page prints (or saves as a PDF) as the document itself, headed by the `document_header` setting, and shows the payments and credits applied to it; an approved invoice or bill offers a credit note copying its lines. Drafting needs `:record`; approving and voiding need `:post`.

### PDFs
With the `ferrum` gem in the host's bundle (the engine doesn't depend on it) and Chrome or Chromium on the server, the engine makes PDFs of what goes to customers and suppliers, from the same layouts the pages print: an invoice, bill or credit note, a statement of account (or every statement at once, one to a page), and a payment, as a receipt (money received) or a payment notice (money paid, with the bills it paid). Their pages get a **Download PDF** button; without `ferrum` they offer printing only (`TudlaAccounting.pdf?` says which).

```ruby
TudlaAccounting::PdfMaker.document(invoice)                          # => the PDF's bytes
TudlaAccounting::PdfMaker.statements([ statement ], open_items: false)
TudlaAccounting::PdfMaker.payment(payment)
```

The page is rendered with the engine's styles inline (the host's compiled `tailwind.css`, or the `pdf_stylesheet` setting) and the browser is barred from fetching anything, so making a PDF reaches nothing on the network. `pdf_browser_options` passes options to `Ferrum::Browser` (Chrome's path, a timeout; in a container that can't sandbox Chrome, `browser_options: { "no-sandbox" => nil }`), and `pdf_paper` picks A4 or Letter. A PDF that can't be made raises `PdfMaker::Error`; the pages say why.

### Emailing invoices, statements and payments
An approved invoice or credit note, a statement of account, and a payment (as its receipt, or a payment notice) each have an **Email** button (`:post`): the email starts from its template, to the contact's email address, and can be changed (To, Cc, subject, message) before it goes. It is recorded (`TudlaAccounting::Delivery`) and sent in the background (`DeliveryJob`, so the host's Active Job backend must run jobs), with the PDF attached when the engine can make PDFs. The page it came from lists its emails, who asked for each, and whether it was sent or failed (with the error, and **Send again**); a contact's page lists their statements' emails; the Sales list marks invoices emailed; and the activity log has `email.sent` and `email.failed`. **Email them all** on the statements page emails every statement it shows, naming the customers or suppliers with no email address. Recording a payment can email its receipt (or payment notice) at once. A statement is made again as it stands when it is sent.

```ruby
draft = TudlaAccounting::EmailDraft.for_document(invoice) # { kind:, to:, subject_line:, message: }
TudlaAccounting::Delivery.request!(subject: invoice, **draft, cc: "boss@northwind.test")
TudlaAccounting::EmailDraft.for_statement(statement, open_items: false) # with the details it is made from
TudlaAccounting::EmailDraft.for_payment(payment)                        # a receipt, or a payment notice
```

Emails go through the host's own ActionMailer setup (delivery method, SMTP), from `document_mail_from` (text, or a callable given the organization; the host's ActionMailer default otherwise) and replying to `document_mail_reply_to`. `document_email_templates` changes each kind's subject and message, with placeholders such as `%{number}`, `%{total}`, `%{amount_due}` and `%{due_on}`. To send them another way, point `document_mailer` at a mailer of your own whose `delivery(delivery, pdf:, filename:)` returns the mail. The dummy app writes them to files in `spec/dummy/tmp/mails` in development.

### Recurring invoices
`TudlaAccounting::RecurringInvoice` is an invoice made again and again (a retainer, a subscription): its customer, lines (as an invoice's: description, quantity, unit price, account, tax code, dimension values), reference and notes, and a schedule as a recurring entry has (`RecurringSchedule`). Each invoice is dated the day it falls due and due `due_days` later, or on the customer's payment terms when that is blank. What happens to each (`issue`): `draft` (the default) leaves it to check and approve, `approve` approves it (numbered and posted), `email` approves it and emails it to the customer as **Email** would.

`RecurringInvoiceRunner.call(organization:, as_of:)` makes every invoice due by then (today by default), catching up any missed. Each template is locked while it runs and moves on in the same transaction, and each invoice's idempotency key is `recurring_invoice:<id>:<date>`, so a date is never invoiced twice. One that can't be made (the customer or an account made inactive since) stops its template, to try again next run; one that can't be approved (its month closed) is left a draft, and one whose customer has no email address isn't emailed. Either way the reason is kept in `last_problem`, shown on its page and the dashboard. `TudlaAccounting::RecurringInvoicesJob` runs it for every organization; schedule it as the recurring entries job is:

```yaml
production:
  tudla_accounting_recurring_invoices:
    class: TudlaAccounting::RecurringInvoicesJob
    schedule: every day at 1am
```

**Sales → Recurring invoices** lists them with their customer, schedule, next date and total, makes the due ones now (`:post`), and adds, edits, deactivates and deletes them with the invoice form's line editor; only those who can post may set one to approve or email. An approved invoice's **Repeat** starts one from it, a template's **Make a draft for today** makes a one-off draft, and each invoice made links back to its template. They are on the audit trail (`recurring_invoice.*`), as is each invoice made.

```ruby
TudlaAccounting::RecurringInvoiceRunner.call(organization: organization) # => #<Result created=[...] approved=[...] emailed=[...] problems=[...]>
```

### Overdue reminders
With `reminder_days` set (say `[7, 14, 30]`), customers of overdue invoices are emailed a reminder on those days after the due date, from the `reminder` template, with the invoice attached: **Sales → Reminders due** lists them (the latest day each invoice has reached; no catching up on earlier ones) and sends them all (`:post`), and `TudlaAccounting::SendRemindersJob`, which the host schedules (daily, in Solid Queue's `config/recurring.yml`, say), sends them for every organization. Each goes once: one already sent or on its way isn't sent again (a failed one is), nor is one for an invoice paid or void, and customers without an email address are named instead. An overdue invoice's page can also **Send reminder** by hand, any time.

```ruby
TudlaAccounting::ReminderRunner.due(organization: organization)  # => [#<Reminder invoice=... days=14 days_overdue=16>, ...]
TudlaAccounting::ReminderRunner.call(organization: organization) # => #<Result sent=[...] no_address=[...]>
```

### Payments
`TudlaAccounting::Payment` is money received from a customer (`kind: "received"`) or paid to a supplier (`"paid"`), through a bank or cash account, in that account's currency: the organization's, or for an account held in another, that one at `exchange_rate` (looked up for `paid_on` when not given), applied only to documents in it. `Payment.record!` saves it and posts its entry straight away, dated `paid_on`, with the payment as its source: the bank account against the account marked receivable (or payable), opening a credit for the contact that is applied to the invoices or bills given, as much to each as said. What isn't applied stays as a credit, applied later (from the payment's page, the contact's or the entry's) or refunded. With `bank_line:` it is matched to that bank statement line too. All or nothing; `ArgumentError` says what's wrong.

```ruby
payment = TudlaAccounting::Payment.record!(organization: organization, kind: "received", contact: northwind, account: bank,
                                           paid_on: Date.current, amount_cents: 500_00, reference: "EFT 88213",
                                           applications: [ { document: invoice, amount_cents: 330_00 } ])
payment.unapplied # $170.00, a credit to apply
payment.void!(on: Date.current, reason: "Bounced") # reverses its entry and takes it off the invoice
```

A foreign payment posts its amount converted at its rate, the bank line and the receivable or payable line (the sub-account in its currency, as its documents use) each carrying the foreign amount, so the bank reconciles in that currency. Applied to an invoice or bill booked at another rate, the difference is posted as a realized exchange gain or loss (see [Foreign exchange](#foreign-exchange)). What is left of it stays a credit in its currency, and its receipt, payment notice, refunds, the lists and statements show it in that currency. The payment form asks for the currency first (when the organization has bank accounts in others), then offers that currency's accounts and what is owed in it.

A refund is a payment too: money paid back to a customer (`kind: "refund"`) or back from a supplier (`"supplier_refund"`), using up what is left of a payment or credit note of theirs (`refund_of:`, no more than is left). Its entry is the bank account against the same receivable or payable account, related to the credit's entry:

```ruby
TudlaAccounting::Payment.record!(organization: organization, kind: "refund", contact: northwind, account: bank,
                                 paid_on: Date.current, amount_cents: 170_00, refund_of: payment)
payment.unapplied # $0.00
```

The engine maps its payments to the receipt, disbursement, refund and supplier_refund roles itself (see `carrying_amount_sources`). A payment isn't changed or deleted once recorded: `void!` reverses its entry (refused while it is matched to a bank statement line), and reversing the entry itself voids it too. Payments are on the audit trail (`payment.recorded`, `payment.voided`).

**Record payment** on an approved invoice or bill (or on a contact's page) opens a form listing the contact's open invoices or bills, oldest due first, to apply it to. **Payments received** and **Payments made** (from the Sales and Purchases pages) list them, searched and downloadable as CSV, and each payment's page shows what it was applied to. A payment or credit note with something left offers to apply it to the contact's other open invoices or bills (one, or oldest first), or to refund it (**Refund to them**, **Record their refund**); so does each credit on the contact's page. Refunds are listed with the payments, and have no receipt or notice to send. On the banking page, an unmatched statement line can be recorded as a payment of an open invoice (money in) or bill (money out), those owing exactly its amount first: it applies as much as is owed, keeps the rest as a credit, and matches the line. Recording and voiding payments need `:post`.

### Pay runs
**Purchases → Pay run** (`:post`) lists the bills owed by a date (a week from today by default), from one bank account's currency, for every supplier or one, grouped by supplier and all ticked. Untick any, change what is paid of each, give the date and a reference, and pay them: one payment to each supplier from that account, applied to its bills, and (by default) its payment notice emailed; suppliers without an email address are named. All the payments are recorded or none, and an error says whose couldn't be. In code:

```ruby
TudlaAccounting::PayRun.due(organization, currency: "AUD", due_by: Date.current + 7) # the bills, by supplier
TudlaAccounting::PayRun.call(organization: organization, account: bank, paid_on: Date.current, reference: "Pay run",
                             bills: [ { document: bill, amount_cents: bill.amount_due.cents } ], email: true)
# => #<Result payments=[...] emailed=[...] no_address=[...]>
```

### API tokens
`TudlaAccounting::ApiToken` lets another system (a shop, a payroll app) reach an organization's books through the JSON API, with the permissions it is given: `read`, `record`, `post` and `administer`, as the `authorize` setting checks them on the pages. Only a SHA-256 digest of the token is kept, so its secret is seen once, when it is issued:

```ruby
token, secret = TudlaAccounting::ApiToken.issue!(organization: organization, name: "Online shop",
                                                 permissions: %w[read record], expires_on: Date.new(2027, 6, 30))
TudlaAccounting::ApiToken.authenticate(secret) # => token, while it isn't revoked or expired
token.revoke!
```

A token acts as itself: what it does is on the audit trail under its name ("API token Online shop"), and `last_used_at` says when it was last used (to the minute). Tokens can't be changed or deleted, only revoked, which stops them at once. **Setup → API tokens** (`:administer`) issues them (showing the secret once, on a page that isn't cached), lists them with what each can do and when it was last used, and revokes them. On the audit trail as `api_token.created` and `api_token.revoked`.

### JSON API
Other systems can read and record in the books over HTTP at `<engine path>/api/v1` (`/tudla_accounting/api/v1` in the dummy app) with an API token sent as `Authorization: Bearer tudla_...`. They can read the organization, accounts, entries with their lines, contacts, invoices and bills with what is owed, payments with what they paid, recurring invoices, the bills a pay run could pay, tax codes, periods, and the reports (`read`); record entries, contacts, invoices and bills as drafts, and recurring invoices that make drafts (`record`); and post and reverse entries, approve and void invoices and bills, record and void payments, pay a batch of bills in a pay run, and run recurring invoices or set them to approve and email (`post`). The token picks the organization; the host's sign-in doesn't apply. Creates take an `Idempotency-Key`, so a retried request doesn't make anything twice, and what a token does is on the audit trail under its name. Each token may make `api_rate_limit` requests a minute (300 by default). Amounts are decimal strings, lists are paged, and `updated_since` returns what changed, for syncing. See [API.md](API.md) for every endpoint.

### Customer and supplier statements
`TudlaAccounting::PartyStatement` is a statement of account for one customer (`type: :receivable`) or supplier (`:payable`) over a run of days, as it would be sent to them:

```ruby
statement = TudlaAccounting::PartyStatement.call(organization: organization, type: :receivable, party: customer,
                                                 from: Date.new(2026, 3, 1), thru: Date.new(2026, 3, 31))
statement.opening    # what they owed at the end of 28 February
statement.lines      # each invoice, bill, refund, payment, credit note and reversal: date, entry, kind, due_date, charge, credit, balance, foreign
statement.closing    # what they owed at the end of 31 March: the aging report's figure for them
statement.aging      # the closing balance by how overdue it is
statement.open_items # what was still open then, as the aging report's lines
```

Balances count each charge and credit as far as it was still open, as the aging report does, so a positive balance is owed by the customer (or to the supplier) and the two reports always agree. When a foreign-currency amount was settled at another rate than it was booked at, a last line, "Exchange differences on settlement and other adjustments", brings the running balance to the closing one. Amounts are in the organization's currency, with each foreign amount on its line. Parties are the records the `related_party_method` setting gives; `PartyStatement.parties(organization, type)` lists those with receivables or payables. Use it to send statements from the host app's own mailer.

The **Statements** page (from Reports, or a party's Statement link on the aging reports) shows one: last month by default, its activity with the running balance or the open items at the end, then the aging and the amount due. It prints on its own (Print or save as PDF), for sending, and downloads as CSV or Excel. **All customers** (or suppliers) shows every statement with something to send for the same dates (a balance at either end or activity in between; for open items, anything open at the end), one to a printed page, and downloads them as one table with a Customer (or Supplier) column. The demo's customers (Northwind, Globex, Initech, Umbrella) have invoices on account to try it with.

### Budgets
`TudlaAccounting::Budget` is a plan for a financial year: an amount for each income and expense account in each month (`BudgetLine`), on the account's own side, as balances are (income and spending as positive amounts; a contra account's count against its section). A year can have several budgets by name, one of them its `main` budget. Accounts with sub-accounts add theirs up, so amounts go on the accounts beneath them.

```ruby
budget = TudlaAccounting::Budget.create!(organization: organization, period: year, name: "Original", main: true)
budget.fill_from_actuals!(last_year, percent: 5) # last year's results, month for month, plus 5%, rounded to whole units
budget.fill_from_budget!(other_budget)           # or a copy of another budget
budget.set_amounts!(sales.id => { march.id => 12_000_00 }) # these accounts' amounts; the others keep theirs
budget.amounts # => { account_id => { month_id => cents } }
```

`set_amounts!` refuses accounts other than the organization's income and expense accounts, an inactive account not already in the budget, and months of other years. An account a budget has amounts for can't be deleted or change category, and a year with a budget can't be deleted. Budgets are on the audit trail (`budget.created`, `budget.updated` with the accounts whose amounts changed, `budget.deleted`).

The **Budgets** page (from Reports) lists them with their income, expenses and net profit. A new one starts blank, from a year's actual results changed by a percentage, or as a copy of another; its page shows the accounts down the side and the months across, with year totals, section totals and net profit, typed into a grid that keeps the totals up to date and spreads an amount typed in the Year column over the months. A budget downloads as CSV or Excel (`BudgetGrid#to_table`) and uploads again (`BudgetGrid#read`): rows are matched by the Code column and columns by month headings such as "Mar 2026", "2026-03" or a date, and accounts without a row keep their amounts. Viewing needs `:read`; adding and changing budgets needs `:record`.

**Budget vs actual:** the profit and loss page's Compare with offers each budget of the period's year (`compare=budget` picks the year's main budget, `compare=budget-<id>` another). A year shows its actual results, the budget, the variance (actual less budget) and its percentage of the budget; a month shows the same for the month and then for the year to date. Each variance is marked F (favourable: more income or profit, or less spending, than budgeted) or U. It downloads as CSV and Excel with the same columns and prints like the other comparisons; a budget's page links to it. In code, `Reports::BudgetComparison.new(budget, period)` is a `Reports::Comparison` of the actual and budget columns, and `Reports::BudgetStatement.new(budget, months, period:)` a budget's amounts over some months as a statement.

### Attachments
With Active Storage set up in the host app (`bin/rails active_storage:install`), entries can carry receipts and other source documents, and invoices, bills and credit notes their files (the supplier's PDF on a bill, say); `TudlaAccounting.attachments?` says whether they can, and the pages leave attachments out until then. The engine ships no Active Storage migration of its own.

- `entry.add_attachments!(files)` attaches uploaded files, or hashes of `io:`, `filename:` and `content_type:`, to a draft or a posted entry (a receipt often arrives after the entry is posted). Each must be of a type in the `attachment_content_types` setting, as Active Storage identifies it from the file's contents (by default PDF, PNG, JPEG, HEIC, WebP, CSV, Excel and email), and no bigger than `attachment_max_size` (10 MB by default); otherwise nothing is attached.
- `entry.remove_attachment!(attachment, reason: nil)` removes one: freely from a draft, but from a posted entry only with a reason, since its files are part of its record.
- Documents do the same (`document.add_attachments!`, `document.remove_attachment!`): an approved document's files, like a posted entry's, come off only with a reason, and are on the audit trail as `document.attachment_added` and `document.attachment_removed`.
- Both are on the audit trail (`entry.attachment_added`, `entry.attachment_removed`) with the file's name, size and checksum, and the reason. Attach and remove files with these methods rather than `entry.attachments.attach`, which skips the checks and the trail. A draft deleted takes its files with it.

The entry and document pages list their files, upload more (`:record` permission) and remove them: a draft's with `:record`, a posted entry's or approved document's with `:administer` and a reason. Files are served through the engine (`/entries/:id/attachments/:id`, `/documents/:id/attachments/:id`), which checks the permissions and the organization. Active Storage's own routes serve a file to anyone with its signed URL, so the engine's pages never link to them; keep that in mind if the host app does.

### Typing amounts
Every amount and number people type, and the JSON API is given, is read one way (`AmountParser`): digits with a decimal mark, optionally grouped in thousands, signed by a leading `+` or `-` or by parentheses for a negative (`(5.00)`). The pages read in the organization's number format (see `number_format` below; `1,234,567.89`, or `1.234.567,89` in comma books), amounts, quantities, exchange rates and tax percentages alike, and the JSON API, files and imports always with `.` for decimals and commas for thousands. Nothing else is read (with `.` for decimals, no `1.234,50`, `10,00`, `1e3`, symbols or words), so a number is never half read, and an amount can't have more decimal places than its currency (cents, or none for the yen); the form or API says what is wrong, and a page says how to write one (`, written like 1.234,56`). Imports (the chart of accounts, open receivables and payables, budgets) round extra places as the `rounding` setting says, as files often carry them; bank statements have their own formats (see [Bank reconciliation](#bank-reconciliation)). The forms' live totals read amounts the same way, and every field is filled the way it is read back, without thousands separators (`tc_amount_field` for amounts, `tc_number` for quantities, rates and percentages: `1234.50` and `2.5`, or `1234,50` and `2,5`).

```ruby
TudlaAccounting::AmountParser.cents("1,234.50", "AUD")              # => 123450
TudlaAccounting::AmountParser.cents("10.005", "AUD")                # ArgumentError: 10.005 has too many decimal places for AUD, which has 2
TudlaAccounting::AmountParser.cents("10.005", "AUD", round: true)   # => 1001
TudlaAccounting::AmountParser.decimal("1.65")                       # => 1.65, for rates, quantities and percentages
```

### Showing amounts
Amounts are written for people one way (`MoneyFormatter`), in the organization's style (`NumberFormat.for(organization)`): the `number_format` setting's decimal mark and thousands separator (`:point` for `1,234.56`, `:comma` for `1.234,56`, or a callable choosing per organization), or without it its currency's, for amounts in any currency, so a euro amount in Australian books reads `1,234.56` and an Australian dollar amount in euro books `1.234,56`. Tables give the number alone (the currency is in the column heading), with negatives in parentheses. An amount standing alone, in a heading, a message, an error, an email or a document, carries the organization's currency symbol (`$1,234.56`), or for any other currency its code (`USD 1,234.56`), since symbols such as `$` are shared. The PDFs and the forms' live totals follow the same style, as do quantities, exchange rates and tax percentages (`2,5`, `GST (12,5%)` in comma books); CSV, Excel and the JSON API have plain numbers (`1234.56`, `AmountParser.text`), and form fields the organization's decimal mark without thousands separators. Views use `tc_money` (in a table) and `tc_money_text` (standing alone).

```ruby
TudlaAccounting::MoneyFormatter.labelled(Money.new(123456, "AUD"), "AUD") # => "$1,234.56"
TudlaAccounting::MoneyFormatter.labelled(Money.new(123456, "EUR"), "AUD") # => "EUR 1,234.56"
TudlaAccounting::MoneyFormatter.number(Money.new(123456, "EUR"), "AUD")   # => "1,234.56"
```

### Posting and balances
`entry.post(posted_at)` posts every line to the period that contains `posted_at`, then stamps the entry. The whole post is one transaction: if any line fails, nothing is posted. Posting an entry twice raises `ArgumentError`. Posts lock the organization's row while they run, so concurrent posts for the same organization take turns instead of overwriting each other's balance updates; other organizations aren't blocked. Each account has one `TudlaAccounting::Balance` per period, holding starting, current and ending amounts. Posting:
- adds the amount to the balance of the deepest period containing `posted_at`, e.g. the month
- rolls it up into every parent period (quarter, year) and every parent account (lines go only to accounts without sub-accounts, so a parent's balance is always the sum of its sub-accounts')
- carries it forward into the starting amount of every later period, so back-dated entries keep later balances correct

**Year end.** Each top-level period is a financial year, and balances carry across years automatically, with no closing step:
- asset, liability and equity accounts open each year with their closing balance from the year before;
- income and expense accounts start each year at zero;
- the previous year's net profit (income less expenses) is added to the organization's retained earnings account (the one with `role: "retained_earnings"`; see account roles below), and to the accounts above it.

Back-dated entries into an earlier year follow the same rules, so later years stay correct whatever order entries are posted in. `Balance.net_profit(organization, year)` returns a year's profit. Without a retained earnings account, income and expenses still restart each year, but the profit isn't carried, so later years' balance sheets won't balance. Marking one later, moving the role to another account or taking it off rebuilds the organization's balances (see below) as part of the change, so every earlier year's profit lands where it now belongs: a client taken on mid-stream can have its years posted first.

**Account roles.** Each organization marks the accounts the books treat specially, at most one of each, on its own chart: `Account#role` is `receivable` (an asset: what customers owe, with the accounts beneath it), `payable` (a liability), `retained_earnings` (equity), `unrealized_fx_gain` or `realized_fx_gain` (income or expense). Set it in the account form, with a `Role` column in the chart of accounts import, or with `role:` in `AccountsCreator`; `Account.for_role(organization, :receivable)` finds it. Since the engine goes by the role and never by code, accounts can be renumbered freely, and every organization's chart can differ. Roles change only through `AccountRoleAssigner.save(account, role)`, which the form (for those with `:administer`), the import and `AccountsCreator` use; a plain `account.update(role:)` is refused. Taking a role another account holds moves it, except that receivables and payables stay on an account once it, or an account beneath it, has posted lines (its open items would be left behind). See [USAGE.md](USAGE.md) for setting up an organization's books step by step, and running them day to day.

**Checking and rebuilding balances.** Balances are a running total kept by posting; the posted entries and the first year's opening balances are the record. `TudlaAccounting::BalanceRebuilder.new(organization).differences` works every balance out again from those, independently of the posting code, and lists any stored figure that differs (or a balance with activity that is missing). `rebuild!` rewrites the stored balances to match, under the same organization lock as posting, and never touches entries. From the command line:

```bash
bin/rails tudla_accounting:balances:check     # lists differences; exits 1 if there are any
bin/rails tudla_accounting:balances:rebuild   # ORGANIZATION=Organization:42 limits either task to one organization
```

**Books posted to accounts with sub-accounts.** Before only accounts without sub-accounts took postings, a parent could hold posted lines or an opening balance of its own. Its balances still add up, but that part shows on none of its sub-accounts, and the account can't take postings now. `BalanceRebuilder#own_amounts` lists such accounts (`OwnAmount` with the `account`, its own posted `lines` and its own `opening_cents`), and `balances:check` warns about each without failing. A correcting entry can't fix them, since it would need a line on the parent, so:

- `TudlaAccounting::OwnPostingsMover.call(account, to: sub_account)` moves the account's own posted lines onto one of its sub-accounts (one without sub-accounts of its own, and in the lines' currency when it is held in one), under the posting lock. The account's balances stay as they are, the sub-account's are rebuilt, and `account.postings_moved` goes on the audit trail. Lines in a closed period are refused; reopen it first. Add a sub-account such as "6090 Other expenses" for lines that belong to none of the existing ones.
- For an opening balance, set it again with `StartingBalanceCreator` in overwrite mode, giving the parent its sub-accounts as `children` that add up to its amount.

### Database integrity
The engine's migrations add unique keys (one balance per account and period, account codes per organization, one carrying amount per line, one exchange rate per currency pair and day) and checks (positive line amounts, known tallies, categories and carrying-amount types). On PostgreSQL, triggers also refuse any change to a posted entry or its lines, or their deletion, from anywhere (a console, a job, raw SQL): correct posted entries by reversing them. Touching `updated_at` is allowed. Triggers likewise refuse posting into a closed period or to an account with sub-accounts, a sub-account beneath an account with posted lines of its own, and any change to audit events. Data maintenance that really must change posted rows can run inside `TudlaAccounting::DatabaseProtection.allowing_posted_changes { ... }`, which lifts the protection for that block's transaction only.

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
Every report downloads as CSV, as shown on its page (period, comparison, months, basis, cash accounts): the pages' **Download CSV** link, or the report's path with `.csv`. With the `caxlsx` gem in the host app's Gemfile (the engine doesn't depend on it; `TudlaAccounting.xlsx?` says whether it's there), the pages also offer **Excel** (`.xlsx`): one sheet, amounts as numbers with their currency's decimal places (none for the yen), dates as dates, text never read as a formula, and the headings and totals in bold. **Print or save as PDF** opens the browser's print dialog: printed pages leave out the navigation, forms and buttons, use light colours whatever the theme, name the organization and when it was printed, print every column of a wide table, and turn landscape for a comparison of more than three periods. `Reports::Tables` lays each report out as a `Reports::Table` (`statement`, `trial_balance`, `aging`, `tax`, `by_dimension`, `cash_flow`; `Reports::GeneralLedger#to_table`), whose `to_xlsx(sheet_name)` writes the workbook and `to_csv` writes amounts as plain numbers (`-1234.50`) and dates as ISO 8601. Text that a spreadsheet would run as a formula (an account or party name starting with `=`, `+`, `-` or `@`) is written with a leading apostrophe. Statements have a row per account with its section, code and level in the tree, then the totals; the aging report has a row per open item, its amount in its bucket's column.

### General ledger and cash flow
`Reports::GeneralLedger.new(organization, from: month, thru: month, account_ids: nil)` lists, for every account lines are posted to (or the ones chosen), the opening balance, each posted line with a running balance on the account's own side, and the closing balance; `to_csv` writes it out, with each line's entry number, reference and description. Reports → General ledger shows it and downloads the CSV.

`Reports::CashFlow.new(organization, from:, thru:, cash_accounts: nil)` is a direct-method cash flow statement: each posted entry that moves cash is attributed to its other lines, grouped by their account's **cash flow activity** — operating, investing or financing, set on the account (inherited from its parent when blank; equity defaults to financing, everything else to operating). Moves between cash accounts cancel out, and `reconciles?` checks that opening cash plus the net change is the closing cash. Cash is the `cash_accounts` given or the `cash_account_codes` setting (each with its sub-accounts); Reports → Cash flow lets you pick them too. With `method: :indirect` (the page's Method choice) it starts instead from the net profit and adds each other balance-sheet account's change over the time, by its activity (receivables growing take cash, payables growing give it); income and expense accounts all count in the net profit, so set accumulated depreciation's activity to operating to show depreciation added back there. Both methods come from the same posted lines and give the same totals.

### Reporting dimensions
`TudlaAccounting::Dimension`s (department, project, location...) each have `DimensionValue`s, managed under Setup → Dimensions; inactive ones stop being offered but stay on the lines that have them. Entry lines are tagged with at most one value of each dimension (`DetailTag`): in `Entry.create_from_ruby_hash` with `dimensions: { "DEPT" => "SALES", "PROJ" => "APOLLO" }` on a line (codes), or with a column per dimension in the entry form. Reversals keep the tags; tax lines aren't tagged. Invoice and bill lines take them the same way (a column per dimension in the form, `dimensions` in the API); approving the document tags each line's posting, so profit and loss by dimension includes sales and purchases. A credit note copies them from what it credits.

`DimensionReport.call(organization, dimension, from:, thru:)` (Reports → Profit and loss by dimension) breaks income and expenses posted in that time down by the dimension's values, with an "Untagged" column for lines without one and a total, and the net profit of each.

### Bank reconciliation
`BankStatementImporter.call(account, path, date_order: :dmy, decimal_mark: ".")` imports a bank statement for an account as `BankStatementLine`s (money in positive, money out negative, in the account's currency), and says how many it imported and skipped and the format it read. It tells the formats apart by what the file holds:
- **CSV:** it finds columns by their usual headers: a date, a description, one signed amount or money in and out columns, and optionally a reference, the running balance and the bank's transaction id. Dates are ISO or, by `date_order`, day or month first. Amounts are written with `decimal_mark` (`"1,234.56"` with `"."`, `"1.234,56"` with `","`), thousands separated by the other mark, a space or an apostrophe; they may carry a currency symbol or code, and show money out by a minus (before or after), parentheses or `DR` (`CR` marks money in). An amount written any other way is refused, naming its row, rather than guessed at. The banking page asks for both.
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
        # The receivable account's sub-account in the invoice's currency:
        # TudlaAccounting::Account.for_role_in_currency!(organization, :receivable, "USD").code
        { account_code: "1100-USD", amount: "USD #{TudlaAccounting::AmountParser.text(invoice.total)}" },
        { account_code: "4000", amount: "USD #{TudlaAccounting::AmountParser.text(invoice.total)}" }
      ]
    } # return nil to skip
  })
end

entry = TudlaAccounting.create_entry_from_source!(invoice) # linked back via source_type/source_id
TudlaAccounting::EntryPostingJob.perform_later(entry.id)
```

Each line's `amount` is a currency code and a number (`"USD 1100.00"`, `"USD -1,100.00"`, `"USD (1100)"`), or a number alone in the organization's currency, read as [typed amounts](#typing-amounts) are: anything else (`"$1,100"`, `"USD lots"`, `"USD 1e3"`, more decimal places than the currency has) raises `ArgumentError` naming the line, as does a foreign amount (`fx: { other_currency_amount:, fx_rate: }`) or rate that can't be read. Write a `Money` with `AmountParser.text`, not `to_s`, which uses the currency's own decimal mark (`1100,00` for the euro).

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
`perf/benchmark.rb` builds a throwaway organization's books (two years, a chart of 30 accounts, taxed and tagged entries on random dates, and a quarter as many invoices and bills for 40 contacts, most of them paid, with credit notes, refunds, a recurring invoice and a budget), then times posting and every report and heavy page, with the number of SQL queries each takes. It checks the balances against the posted lines with `BalanceRebuilder`, and deletes the books afterwards (unless `KEEP=1`):

```bash
docker compose exec rails bash -lc 'ENTRIES=10000 bin/rails runner perf/benchmark.rb'
```

With 10,000 entries and 2,500 invoices and bills (41,000 lines), posting takes about 27 ms an entry and approving a document or recording a payment about 80 ms. The financial reports and the general ledger, entries, banking, payments, budget and contacts pages answer in under a second, in queries that don't grow with the books: reports read balances for all accounts in a handful, and long lists come a page at a time. The aging, the dashboard and a contact's page read what is owed on every open item in a few queries too (the dashboard answers in 0.6 seconds), and the statements for every customer take a few queries for each customer (1.6 seconds for 30). The Sales and Purchases lists, the pay run and the payment form answer in a fraction of a second, in under 20 queries.

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
The dummy app doubles as a demo. The seeds build **Demo Co**: two years of books with a chart of accounts, GST, a department dimension, a couple of hundred posted entries and a few drafts, the first half of last year closed, and a bank statement to reconcile for the operating account. `bin/setup` runs them when it creates the database; `bin/setup --reset` drops the databases and rebuilds them, and `bin/rails app:db:seed` seeds an existing one. They also build **Demo GmbH**, smaller books kept in euros, so amounts read and write as `1.234,56` and dollars are the foreign currency: invoices to a US customer at their own rates, one paid into a dollar account at another (an exchange gain), and VAT at 19% and 7%. The demo's `forex_rate_provider` (`Demo::ForexRateProvider`) makes up USD/EUR rates for any date, so a foreign invoice or payment left without a rate gets the day's in either set of books. With `bin/dev` running, open `/session/new` and choose "Open the demo books" (or "Open the euro demo books"); that seeds them first if they aren't there yet. Seeding again leaves the books alone, apart from adding the new year's periods once the year turns.

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
  config.number_format = nil              # how pages write and read numbers: :point (1,234.56), :comma (1.234,56),
                                          # or ->(organization) { ... } giving either; nil for the currency's own marks
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

  # Invoices, bills and credit notes (the engine's own documents)
  config.document_number_format = { "sales_invoice" => "%<number>05d" } # over INV-0001, CN-0001, BILL-0001, SC-0001; or ->(document) { ... }
  config.document_header = ->(organization) { "#{organization.name}\n#{organization.address}" } # who a printed document is from

  # PDFs (with the ferrum gem): Ferrum::Browser options, the paper, and the compiled stylesheet
  config.pdf_browser_options = { browser_path: "/usr/bin/chromium", timeout: 60 }
  config.pdf_paper = :A4                  # or :Letter
  config.pdf_stylesheet = nil             # found among the host's assets as tailwind.css; or a path, or ->{ css }

  # Emailing documents to customers and suppliers (sent through the host's ActionMailer setup)
  config.document_mail_from = ->(organization) { "#{organization.name} <accounts@example.com>" } # or text; the ActionMailer default if nil
  config.document_mail_reply_to = "accounts@example.com"
  config.document_email_templates = { invoice: { subject: "Invoice %{number} from %{organization}" } } # over the defaults
  config.document_mailer = "TudlaAccounting::DocumentMailer" # or one of the host's: delivery(delivery, pdf:, filename:)
  config.reminder_days = [ 7, 14, 30 ]   # days after the due date to remind customers of overdue invoices (none by default)

  # The JSON API (see API.md): requests a minute per token (nil for no limit), and where they're counted
  config.api_rate_limit = 300
  config.api_rate_limit_store = nil # Rails.cache

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
