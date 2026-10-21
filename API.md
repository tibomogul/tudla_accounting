# JSON API

Other systems (a shop, a payroll app, a reporting tool) can read an organization's books, and record in them, over HTTP. The API is part of the engine, mounted under the engine's path: with the engine at `/tudla_accounting`, it is at `/tudla_accounting/api/v1`.

## Authentication

Every request carries an API token, issued under **Setup → API tokens** (or with `TudlaAccounting::ApiToken.issue!`; see the README):

```
GET /tudla_accounting/api/v1/organization
Authorization: Bearer tudla_6qN3...
Accept: application/json
```

The token picks the organization: there is no organization parameter, and nothing of another organization's can be reached. The host app's own sign-in, sessions and CSRF checks don't apply to the API; only the token does. Use HTTPS: the token is a bearer secret.

Each token has permissions, the same ones the pages check:

| Permission | Allows |
|---|---|
| `read` | Every `GET` |
| `record` | Drafting: entries, contacts, invoices and bills (and deleting drafts) |
| `post` | Posting and reversing entries, approving and voiding invoices and bills, recording and voiding payments |
| `administer` | Nothing in the API yet |

A token without the permission an endpoint needs gets `403`. A missing, unknown, revoked or expired token gets `401` with `WWW-Authenticate: Bearer realm="TudlaAccounting", error="invalid_token"`.

## Rate limit

Each token may make `api_rate_limit` requests a minute (300 by default; `nil` for no limit), counted in fixed one-minute windows. Responses carry `X-RateLimit-Limit` and `X-RateLimit-Remaining`; past the limit the response is `429` with `Retry-After` (seconds until the next window). The counts are kept in `api_rate_limit_store`, or `Rails.cache` when that isn't set: a store shared by all the app's processes (Solid Cache, Redis) limits them all; a null store limits nothing.

```ruby
TudlaAccounting.configure do |config|
  config.api_rate_limit = 600
  config.api_rate_limit_store = ActiveSupport::Cache::RedisCacheStore.new(url: ENV["REDIS_URL"])
end
```

## Conventions

- **Amounts** are decimal strings in the currency given beside them (`"1234.50"`, `"-12.00"`), never floats.
- **Dates** are ISO 8601 (`"2026-03-31"`), in the books' time zone (the `time_zone` setting). **Times** are ISO 8601 with their offset.
- **Accounts, tax codes and dimensions** are named by their codes.
- **Lists** are paged: `page` (from 1) and `per_page` (50 by default, at most 200). The response is `{ "data": [...], "meta": { "page", "per_page", "total_count", "total_pages" } }`. A single record is `{ "data": {...} }`.
- **Syncing**: lists of accounts, entries, contacts, documents and payments take `updated_since` (an ISO 8601 time) for records changed after it.
- **Errors** are `{ "error": { "code", "message" } }`: `invalid_token` (401), `forbidden` (403), `not_found` (404), `no_periods` (404: a report needs periods the books don't have yet), `invalid_request` (422: something sent that can't be read or done, the message says what), `invalid` (422: a record that fails its checks, with `"details": { "field": ["message"] }`), `rate_limited` (429).
- **Writing**: send JSON (`Content-Type: application/json`). A create answers `201` with the record as a `GET` shows it. Whatever a request does happens entirely or not at all, and is on the audit trail under the token's name ("API token Online shop").

## Reading

### Organization

`GET /organization`: the organization the token reaches, and the token.

```json
{ "data": { "id": 4, "name": "Acme", "currency": "AUD",
            "token": { "name": "Online shop", "permissions": ["read"], "expires_on": null } } }
```

### Accounts

`GET /accounts`: the chart of accounts, by code. Filters: `category` (asset, liability, equity, income, expense), `active` (true or false), `updated_since`.

`GET /accounts/:id`: by id, or by code (`/accounts/4000`).

```json
{ "id": 12, "code": "4010", "name": "Consulting", "category": "income", "role": null, "currency": null,
  "parent_code": "4000", "contra_account_code": null, "cash_flow_activity": null, "active": true,
  "created_at": "2026-01-02T03:04:05Z", "updated_at": "2026-01-02T03:04:05Z" }
```

`role` is the role the books give the account (`receivable`, `payable`, `retained_earnings`, `unrealized_fx_gain`, `realized_fx_gain`) or null; `currency` is null for the organization's own.

### Entries

`GET /entries`: journal entries with their lines, oldest first. Filters: `status` (posted or draft), `from` and `to` (the days entries are dated, inclusive), `account` (a code; its sub-accounts too), `reference`, `updated_since`.

`GET /entries/:id`

```json
{ "id": 81, "number": "#42", "status": "posted", "particulars": "Invoice INV-0001 – Northwind", "reference": "INV-0001",
  "transacted_at": "2026-04-01T00:00:00+10:00", "posted_at": "2026-04-01T00:00:00+10:00", "reverse_on": null,
  "related_entry_id": null, "source": { "type": "document", "id": 7 }, "idempotency_key": null, "currency": "AUD",
  "lines": [
    { "account_code": "1100", "debit": "275.00", "credit": null, "description": null, "tax_code": null, "tax_role": null, "foreign": null, "dimensions": {} },
    { "account_code": "4010", "debit": null, "credit": "250.00", "description": "Consulting", "tax_code": "GST", "tax_role": "base", "foreign": null, "dimensions": { "DEPT": "SALES" } },
    { "account_code": "2200", "debit": null, "credit": "25.00", "description": "Consulting", "tax_code": "GST", "tax_role": "tax", "foreign": null, "dimensions": {} }
  ],
  "created_at": "...", "updated_at": "..." }
```

`number` is null for a draft. `source` says what the entry was posted for: `{ "type": "document" }` (an invoice, bill or credit note), `"payment"`, `"recurring_entry"`, or a host app's own model (its class name, underscored), or null. A line in a foreign currency has `"foreign": { "currency": "EUR", "amount": "100.00", "rate": "1.65" }`.

### Contacts

`GET /contacts`: customers and suppliers, by name. Filters: `kind` (customer or supplier; "both" counts as either), `q` (name, email or tax number), `active`, `updated_since`.

`GET /contacts/:id`

```json
{ "id": 3, "name": "Northwind", "kind": "both", "email": "ap@northwind.test", "phone": null, "address": "1 Main St\nSydney",
  "tax_number": "51 824 753 556", "payment_terms_days": 30, "notes": null,
  "default_account_code": "4010", "default_tax_code": "GST", "active": true, "created_at": "...", "updated_at": "..." }
```

### Invoices, bills and credit notes

`GET /documents`: oldest first. Filters: `kind` (sales_invoice, sales_credit, bill, supplier_credit), `status` (draft, approved, void), `contact_id`, `number`, `from` and `to` (their dates), `updated_since`.

`GET /documents/:id`

```json
{ "id": 7, "kind": "sales_invoice", "status": "approved", "payment_status": "part_paid", "number": "INV-0001",
  "contact": { "id": 3, "name": "Northwind" }, "reference": "PO 9", "issued_on": "2026-04-01", "due_on": "2026-05-01",
  "tax_inclusive": false, "currency": "AUD", "subtotal": "250.00", "tax": "25.00", "total": "275.00", "amount_due": "75.00",
  "credited_document_id": null, "entry_id": 81, "notes": null,
  "lines": [ { "description": "Consulting", "quantity": "2.5", "unit_price": "100.00", "amount": "250.00",
               "account_code": "4010", "tax_code": "GST", "tax": "25.00" } ],
  "approved_at": "...", "voided_on": null, "void_reason": null, "created_at": "...", "updated_at": "..." }
```

`payment_status` is `draft`, `void`, or for an approved document `unpaid`, `part_paid` or `paid` (for a credit note: how much of it has been applied). `amount_due` is what is still owed (or, on a credit note, left to apply). A line's `amount` is its quantity times its unit price; with `tax_inclusive` it includes its `tax`.

### Payments

`GET /payments`: oldest first. Filters: `kind` (received or paid), `status` (posted or void), `contact_id`, `from` and `to` (the days they were paid), `updated_since`.

`GET /payments/:id`

```json
{ "id": 5, "kind": "received", "status": "posted", "contact": { "id": 3, "name": "Northwind" }, "account_code": "1000",
  "paid_on": "2026-04-10", "currency": "AUD", "amount": "300.00", "unapplied": "100.00", "reference": "EFT 1", "notes": null, "entry_id": 90,
  "applied": [ { "document_id": 7, "number": "INV-0001", "entry_id": 81, "amount": "200.00", "applied_at": "...", "active": true } ],
  "voided_on": null, "void_reason": null, "created_at": "...", "updated_at": "..." }
```

`unapplied` is the credit the contact still has from it. An application taken off again (the payment voided, say) has `"active": false`.

### Tax codes and periods

`GET /tax_codes`: `{ "id", "code", "name", "kind" (sales or purchases), "rate" ("0.1" for 10%), "account_code", "active" }`.

`GET /periods`: financial years and their months, latest first: `{ "id", "label" ("Mar 2026"), "kind" (year or month), "year_id", "from_date", "thru_date", "closed" }`. Their ids pick the periods reports cover.

## Recording

### Idempotency

`POST /entries`, `POST /documents` and `POST /payments` take an `Idempotency-Key` header (up to 200 characters; an order number, a UUID): a request with a key an earlier one used gets what that one made, `200` with `Idempotent-Replayed: true`, instead of making it again, so a request can be retried safely after a timeout. The key is kept with what was made, for good, and it is the key that counts, not the body: use a new key for a new thing.

```
POST /tudla_accounting/api/v1/entries
Authorization: Bearer tudla_6qN3...
Content-Type: application/json
Idempotency-Key: shop-order-1042
```

### Entries

`POST /entries` (`record`; with `"post": true`, `post` too) records a draft, or posts it at once:

```json
{ "date": "2026-04-10", "particulars": "Shop order 1042", "reference": "1042", "post": true,
  "lines": [
    { "account_code": "1000", "debit": "110.00" },
    { "account_code": "4000", "credit": "100.00", "tax_code": "GST", "description": "Widgets", "dimensions": { "DEPT": "SALES" } }
  ] }
```

- `date` is a day (the start of it in the books' time zone) or an ISO 8601 time. Posting puts the entry in the month of its date.
- Each line has a `debit` or a `credit` (a positive decimal string), an `account_code`, and optionally a `description`, `dimensions` (dimension code to value code), and a `tax_code`: the tax is worked out and added on a line of its own, on the same side, to the code's account (above, 10.00 to GST). With `"tax_inclusive": true` (on the entry, or a line) the amount includes the tax, which is split out of it.
- A line in an account held in another currency gives that amount too: `"foreign": { "currency": "EUR", "amount": "100.00", "rate": "1.65" }`, the debit or credit being its value in the organization's currency.
- `reverse_on` (a date) posts its reversal that day too: an accrual.
- The debits and credits must balance (after tax).

`POST /entries/:id/post` (`post`) posts a draft, dated as it is. `POST /entries/:id/reverse` (`post`) reverses a posted entry on `on` (a date; today by default) and answers with the reversal. `DELETE /entries/:id` (`record`) deletes a draft (`204`); a posted entry is reversed instead.

### Contacts

`POST /contacts` and `PATCH /contacts/:id` (`record`) take `name`, `kind` (customer, supplier, both), `email`, `phone`, `address`, `tax_number`, `payment_terms_days`, `notes`, `active`, `default_account_code` and `default_tax_code`. A `PATCH` changes only the fields sent; `null` clears one.

### Invoices, bills and credit notes

`POST /documents` (`record`; with `"approve": true`, `post` too) drafts one, or approves it at once (numbered and posted):

```json
{ "kind": "sales_invoice", "contact_id": 3, "issued_on": "2026-04-01", "reference": "PO 9", "approve": true,
  "lines": [ { "description": "Consulting", "quantity": "2.5", "unit_price": "100.00", "account_code": "4010", "tax_code": "GST" } ] }
```

`kind` is `sales_invoice`, `sales_credit`, `bill` or `supplier_credit`. `due_on` defaults to the contact's payment terms after `issued_on`. Lines need a `description`, `unit_price` and `account_code` (not the receivables or payables account); `quantity` is 1 if not given; `tax_code` must be of the document's side. `tax_inclusive` says the prices include the tax. A credit note can name the approved invoice (or bill) it credits, `credited_document_id`, and is applied to it when approved.

Their files: an entry's or document's JSON lists them under `attachments` (`id`, `filename`, `content_type`, `byte_size`, `created_at`; empty when the app keeps no attachments). `POST /documents/:id/attachments` and `POST /entries/:id/attachments` (`record`) upload them as multipart form data, `file` (or several as `files[]`), each checked as on the pages (the `attachment_content_types` and `attachment_max_size` settings); the answer lists the record's files. `GET /documents/:id/attachments/:attachment_id` (and the same for entries) downloads one.

`PATCH /documents/:id` (`record`) changes a draft: the fields sent, and with `lines`, all its lines. `DELETE /documents/:id` (`record`) deletes a draft. `POST /documents/:id/approve` (`post`) approves a draft. `POST /documents/:id/void` (`post`) voids an approved one, reversing its entry on `on` (a date) with a `reason`; it is refused while payments or credit notes are applied to it.

### Payments

`POST /payments` (`post`) records a payment, posted at once, and applies it:

```json
{ "kind": "received", "contact_id": 3, "account_code": "1000", "paid_on": "2026-04-10", "amount": "300.00", "reference": "EFT 88213",
  "applications": [ { "document_id": 7, "amount": "275.00" } ] }
```

`kind` is `received` (from a customer, applied to their invoices) or `paid` (to a supplier, applied to their bills). `account_code` is the bank or cash account it went through, in the organization's currency. Each application can't be more than is still owed on its document, nor all of them more than the payment; what isn't applied stays as a credit for the contact. `POST /payments/:id/void` (`post`) voids it, reversing its entry on `on` with a `reason` and taking it off what it paid; refused while it is matched to a bank statement line.

## Reports

`GET /reports/:report` lays a report out as its page's download does:

```json
{ "report": "trial_balance",
  "data": { "headings": ["Code", "Account", "Debit", "Credit"],
            "rows": [ { "cells": ["1000", "Bank", "500.00", null], "total": false },
                      { "cells": [null, "Total", "775.00", "775.00"], "total": true } ] } }
```

| Report | Parameters |
|---|---|
| `balance_sheet` | `period_id` (a month; this month by default), `compare` (previous, last_year, months) |
| `profit_and_loss` | `period_id` (a year or month; this year by default), `compare` (previous, last_year, months, budget for the year's main budget, `budget-<id>` for another) |
| `trial_balance` | `period_id` (a month) |
| `receivables`, `payables` | `as_of` (a date; today by default): the aging report |
| `tax` | `from_id`, `thru_id` (months; this month by default), `basis` (accrual or cash) |
| `general_ledger` | `from_id`, `thru_id`, `account` (a code) |
| `cash_flow` | `from_id`, `thru_id` (the start of the year to this month by default), `method` (direct or indirect); needs the `cash_account_codes` setting |

A period id that isn't one of the organization's gets `404`.
