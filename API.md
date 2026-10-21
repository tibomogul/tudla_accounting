# JSON API

Other systems (a shop, a payroll app, a reporting tool) can read an organization's books over HTTP. The API is part of the engine, mounted under the engine's path: with the engine at `/tudla_accounting`, it is at `/tudla_accounting/api/v1`.

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
| `read` | Everything on this page |
| `record`, `post`, `administer` | Writing (coming in the next version of this document) |

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
- **Errors** are `{ "error": { "code", "message" } }`: `invalid_token` (401), `forbidden` (403), `not_found` (404), `no_periods` (404: a report needs periods the books don't have yet), `invalid_request` (422: a parameter that can't be read), `rate_limited` (429).

## Endpoints

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

### Reports

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
