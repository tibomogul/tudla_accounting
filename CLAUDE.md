# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

TudlaAccounting is a **Rails 8.1 mountable engine** with namespace isolation (`TudlaAccounting::`) and the Solid trifecta (Solid Queue, Solid Cache, Solid Cable), Tailwind CSS v4, and Importmap Rails.

## Commands

All commands run inside the Docker container:

```bash
docker compose exec rails bash -lc 'RAILS_ENV=test bundle exec rspec'                            # Run all specs
docker compose exec rails bash -lc 'RAILS_ENV=test bundle exec rspec spec/integration/solid_stack_spec.rb'  # Run single spec file
docker compose exec rails bash -lc 'cd spec/dummy && RAILS_ENV=test bundle exec rspec'           # Run the demo app's specs
docker compose exec rails bash -lc 'bundle exec rubocop'                                          # Lint
docker compose exec rails bash -lc 'bundle exec rubocop -a'                                       # Auto-fix lint
docker compose exec rails bash -lc 'bin/setup'                                                    # Deps + create/migrate DBs (seeds Demo Co the first time)
docker compose exec rails bash -lc 'bin/setup --reset'                                            # Drop, recreate and reseed the dev (and test) DBs
docker compose exec -d rails bash -lc 'bin/dev'                                                   # Start dev server (Foreman: web + css + worker)
```

> **Note:** Always prefix `bundle exec rspec` with `RAILS_ENV=test`. The container has `RAILS_ENV=development` set in its environment, which overrides the `||=` default in `rails_helper.rb`.

- **Restart the dev server after editing `lib/`** (e.g. `lib/tudla_accounting.rb`, where the configuration lives): it isn't reloaded, so pages fail with `undefined method` for a new setting. Stop it by PID (`docker compose exec -T rails ps -eo pid,args`, then `kill -TERM` puma, the solid-queue supervisor and the tailwind watcher); `pkill -f <pattern>` inside `bash -lc '...'` matches and kills its own shell. Then `rm -f spec/dummy/tmp/pids/server.pid` and start `bin/dev` again.
- `bin/setup --reset` fails while the dev server runs (it holds the queue DB); stop the server first.
- After a migration, `db:migrate` rewrites every `check_constraint` string in `spec/dummy/db/schema.rb` (PostgreSQL's canonical form). Revert the file and hand-edit only the version and the new column/table, then rebuild the test DB (see Testing Gotchas).

## Architecture

This is a **Rails engine gem** (not a standalone app). All application code lives under the `TudlaAccounting::` namespace via `isolate_namespace TudlaAccounting` in `lib/tudla_accounting/engine.rb`.

- `lib/tudla_accounting.rb` — main entry point, requires Solid gems, Tailwind, Importmap
- `lib/tudla_accounting/engine.rb` — engine configuration with namespace isolation
- `spec/dummy/` — full Rails 8.1 app used for testing the engine (has its own config, routes, db); uses **Tailwind CSS v4** and **DaisyUI** for styling
- Engine is mounted at `/tudla_accounting` in the dummy app's routes

### Dummy app: harness and demo

The dummy app is both the engine's test harness and a demo. Keep the two apart:

- **Harness**: `Organization`, `ApplicationController#current_organization`, the stand-in login (`SessionsController`), `PagesController`, `config/initializers/tudla_accounting.rb`. The engine's specs may rely on these.
- **Demo**: everything under the `Demo::` namespace (`spec/dummy/app/*/demo/`; Zeitwerk makes the module from those folders), `config/initializers/demo.rb` (the sign-in hooks), the `demo` routes and `db/seeds.rb` (`Demo::Seeder`).
- The demo loads only when `config.x.demo` is set (`spec/dummy/config/application.rb`). That's on in development and off in test unless `TUDLA_DEMO=1`. When it's off, Zeitwerk ignores the demo folders.
- The demo's specs live in `spec/dummy/spec` and are run from `spec/dummy`; their `rails_helper` sets `TUDLA_DEMO=1`. The root `.rspec` excludes them from the engine's run.
- Engine code, engine specs and the harness must never reference the demo (`Demo::`, its route helpers, `config.x.demo`). The harness offers hooks instead, declared in `config/application.rb` and set by the demo's initializer: `config.x.sign_in_partial` (rendered on the sign-in page) and `config.x.sign_in_organizations` (filters the organizations listed). Only `config/application.rb` and `config/routes.rb` wire the demo in. `spec/integration/demo_isolation_spec.rb` boots the app in a child process to check that the engine's run loads none of it, and checks that no engine or harness file names it. Demo code may use anything from the engine.
- The isolation covers code and routes, not the schema: a demo table would go into the dummy app's `schema.rb`, which the engine's test database loads too.
- Both `rails_helper`s share `spec/rails_setup.rb` (test-env check, schema maintenance, triggers, common RSpec config); put setup both suites need there.

### Multi-Database (Solid Trifecta)

The dummy app uses four separate PostgreSQL databases (the `db` service in `docker-compose.yml`): `primary`, `queue`, `cache`, `cable`. Each Solid gem requires `connects_to` configuration in environment files (e.g., `config.solid_queue.connects_to = { database: { writing: :queue } }`).

**Critical:** Do NOT use both `database:` keys in `database.yml` AND `connects_to` in environment config — they conflict.

### Migrations

Engine migrations live at `db/migrate/` in the **engine root** (they ship with the gem). The dummy app has its own `spec/dummy/db/migrate/` for dummy-only models (e.g., `Organization`).

**Always generate and run migrations from the engine root**, not from `spec/dummy/`:

```bash
docker compose exec rails bash -lc 'bin/rails generate migration AddFooToBar'   # lands in db/migrate/
docker compose exec rails bash -lc 'bin/rails db:migrate'                       # migrates dummy app, sees both paths
docker compose exec rails bash -lc 'RAILS_ENV=test bin/rails db:migrate'        # test DB
```

Why: Rails 8.1 does **not** auto-append engine migration paths to the host app's paths. The engine root's `bin/rails` (with `ENGINE_PATH` set) is the only context where both `db/migrate/` and `spec/dummy/db/migrate/` are visible together. Running `bin/rails db:migrate` from `spec/dummy/` will silently skip the engine migrations.

### Money: one way in, one way out

- **Reading:** every typed or given amount goes through `AmountParser` (`cents`, `decimal`); never `to_f`, `BigDecimal()` or `Money.from_amount` on raw input. Controllers use `amount_cents`/`typed_decimal` (`ApplicationController`), the API `cents`/`decimal` (`Api::V1::BaseController`); imports pass `round: true`.
- **Number format:** the pages read and write numbers in the organization's `NumberFormat` (`config.number_format`: `:point`, `:comma`, or nil for the home currency's marks), one style only. The JSON API, CSV/Excel files and imports always use `.`.
- **Writing:** views use `tc_money` (table columns) / `tc_money_text` (standalone, with symbol or code); services use `MoneyFormatter.number`/`labelled` with the organization. Form fields are filled with `tc_amount_field` (amounts) and `tc_number` (quantities, rates, percentages), with no thousands separators, so a form saved unchanged reads back the same. `AmountParser.text` writes amounts for files and `Entry.create_from_ruby_hash`.
- The forms' live totals (`app/javascript/tudla_accounting/amounts.js`) read the marks from `<body data-tc-decimal-mark data-tc-thousands-separator>`.

### Accounts and posting

- Only leaf accounts take postings: an account with sub-accounts is refused by the model (`Account#posting_blocker`) and by DB triggers (`DatabaseProtection`). Forms offer only postable accounts. `OwnPostingsMover` moves an old parent's own lines down; `bin/rails tudla_accounting:balances:check` warns about them.
- Balances roll up through the account tree and the period tree (`BalancePoster`, `BalanceRebuilder`); a parent's balance must always equal the sum beneath it.
- Giving an account the receivable or payable role creates a home-currency sub-account `"<code>-<currency>"` (e.g. `1100-USD`), and foreign currencies get their own; postings go to these via `Account.for_role_in_currency!`, never to the role account itself.

### JSON API

Controllers in `app/controllers/tudla_accounting/api/v1/` build on `BaseController` (`body`, `cents`, `decimal`, `account_by_code`, `contact_by_id`, `date_param`, `render_page`, `require_permission!`, the `permits` DSL) and `Representation` (`*_json`). Creating endpoints honour an `Idempotency-Key` header (`replay` / `render_made`; the key is stored on the record). Document every endpoint in `API.md`.

### Ancestry

`has_ancestry` must specify `ancestry_format: :materialized_path2` whenever the migration declares `null: false, default: "/"` on the ancestry column. The ancestry 5.x default format is `:materialized_path`, which uses `nil` for the root and crashes against a NOT NULL column.

## Testing Gotchas

- The accounts the engine treats specially are marked by `role` on the account (`Account::ROLES`), not by settings. Specs using `"with entry source models"` must mark their receivable and payable accounts themselves (`role: "receivable"` on 1100, `role: "payable"` on 2100, by convention; each then gets a home-currency sub-account such as `1100-USD`, which is where lines post), and give the retained earnings or exchange gain accounts their roles when they need them. Roles change only through `AccountRoleAssigner` (`save`, or `save!` to raise); a plain `update(role:)` is refused. The account factory's `role:` goes through it after create, and `Account.create!(role:)` doesn't work. Changing retained earnings on books with balances rebuilds them (`BalanceRebuilder#rebuild!`) in the same transaction
- `USAGE.md` is tested: `spec/integration/usage_guide_spec.rb` runs its ```ruby blocks in order as one console session (picking them by the heading they're under, and running its `bin/rails tudla_accounting:*` lines as rake tasks), and `spec/system/usage_guide_spec.rb` follows its UI steps by the labels it names. Keep every Ruby block runnable after the ones before it (write alternatives as comments), and update both specs when a heading or a UI label changes
- Specs that change `TudlaAccounting.configuration` must `include_context "with isolated TudlaAccounting configuration"` (`spec/support/configuration.rb`), which restores it afterwards
- In API request specs, send no JSON body with a GET (`params: (body.to_json unless method == :get)`): a body replaces the query string
- Use `stub_const` for inline job classes in specs (Solid Queue requires named classes)
- SolidCache hashes keys internally — don't query the DB by raw key name
- Use `TudlaAccounting::Engine.routes.url_helpers` for engine route helpers in specs
- Use `main_app.` prefix for host app routes within engine context
- FactoryBot factories go in `spec/factories/`, auto-loaded via engine initializer
- `spec/integration/posting_concurrency_spec.rb` turns off transactional tests and uses real threads and PostgreSQL row locks; it deletes its own data afterwards. Any spec that holds a lock in a thread must release it in an `ensure`, or the cleanup blocks forever
- PostgreSQL triggers (`TudlaAccounting::DatabaseProtection`) refuse updates and deletes of posted entries and their lines, posting into closed periods, and changes to audit events. Non-transactional specs must delete the audit events they create too. Specs that need to tamper with posted rows (or clean them up outside a transaction) must wrap it in `TudlaAccounting::DatabaseProtection.allowing_posted_changes { ... }`. `rails_helper` installs the triggers before the suite, since `schema.rb` can't hold them
- `spec/rails_helper.rb` adds the engine's `db/migrate` to `DatabaseTasks.migrations_paths` so `maintain_test_schema!` sees engine migrations as applied; if specs report pending migrations after a schema change, rebuild the test DB (`RAILS_ENV=test bin/rails db:drop db:create db:schema:load`)

## Performance

`perf/benchmark.rb` (run with `bin/rails runner`, `ENTRIES=` to size it) times posting and every report/page with SQL query counts against a generated organization in the dev database, and verifies balances with `BalanceRebuilder`. Rerun it after changing posting (`BalancePoster`), balance reads (`Balance.peek_all`) or report queries; a page's query count shouldn't grow with the number of accounts or rows. `ENTRIES=10000` takes about 13 minutes, so run it in the background.

## UI Development

### Dummy App
Use **DaisyUI** components for all UI work in the dummy app. Reference docs: https://daisyui.com/llms.txt

### Engine
Use **Tailwind CSS v4 only** — no DaisyUI dependency. Engine styles must be self-contained and must not rely on DaisyUI being present in the host app. However, ensure engine styles are compatible with DaisyUI (i.e. they don't conflict when DaisyUI is also loaded).

## Tailwind CSS v4 + Engine Architecture

### How the CSS pipeline works

The engine's Tailwind source lives at `app/assets/tailwind/tudla_accounting/engine.css`. It is **not** built standalone — it is compiled into the **host app's** (or dummy app's) `tailwind.css` via an import stub.

The dummy app opts in at `spec/dummy/app/assets/tailwind/application.css`:
```css
@import "../builds/tailwind/tudla_accounting";
```

That stub file (`spec/dummy/app/assets/builds/tailwind/tudla_accounting.css`) re-imports the engine source using an absolute path. When the dummy app runs `tailwindcss:build`, it processes this chain and compiles all engine CSS inline into the output `tailwind-xxx.css`.

**To rebuild CSS after changes to engine views or engine.css:**
```bash
docker compose exec rails bash -lc 'cd spec/dummy && bundle exec rails tailwindcss:build'
```

Always rebuild after adding new Tailwind classes to engine views — Tailwind v4 scans source files at build time.

`bin/dev`'s watcher rebuilds automatically for edits to existing engine views, helpers and JavaScript, but **not** for edits to `engine.css` itself (it is imported by absolute path from outside the dummy app, so the watcher doesn't track it), nor for new view files in new directories, and it only picks up new `@source` directories when it starts. After editing `engine.css` or adding views, run the build command above (or restart `bin/dev`).

### Engine layout CSS reference

The engine layout (`app/views/layouts/tudla_accounting/application.html.erb`) uses:
```erb
<%= stylesheet_link_tag "tailwind", media: "all" %>
```
This references the **host app's compiled** `tailwind.css`, which already includes the engine CSS. Do NOT reference `tudla_accounting/application` for Tailwind styles — the Sprockets manifest cannot reach the Tailwind build output.

### Source scanning in engine.css

The `@source` directive in `engine.css` tells Tailwind where to scan for class usage:
```css
@source "../../../views";  /* resolves to app/views/ from engine.css location */
```
This is resolved relative to `engine.css`. When the host app builds, Tailwind follows the import chain and uses this path to find engine views. Any new view directories added to the engine must be reachable from this source path.

### CSS variable strategy for theming

Engine views must never use DaisyUI component classes. Instead, use **`--tc-*` CSS custom properties** (prefixed to avoid collision with DaisyUI's `--color-*` variables) defined in `engine.css`.

Theme priority (defined in `engine.css`):
1. `[data-theme="dark"]` — explicit DaisyUI dark theme on `<html>` (host app compatibility)
2. `@media (prefers-color-scheme: dark) { :root:not([data-theme]) }` — OS dark mode fallback when no DaisyUI theme is set
3. `:root` defaults — light

Use these variables in views with Tailwind v4 arbitrary values:
```erb
<div class="bg-[var(--tc-bg)] text-[var(--tc-text)]">
```

Available tokens: `--tc-bg`, `--tc-bg-subtle`, `--tc-surface`, `--tc-border`, `--tc-text`, `--tc-text-muted`, `--tc-primary`, `--tc-primary-fg`, `--tc-accent`, `--tc-code-bg`.

### Theme sync with host app

The engine layout reads `localStorage('theme')` on page load to stay in sync with DaisyUI's theme toggle:
```html
<script>
  (function() {
    var t = localStorage.getItem('theme');
    if (t) document.documentElement.setAttribute('data-theme', t);
  })();
</script>
```
This is a best-effort sync — it only works when the host app uses the same `localStorage('theme')` convention (as the dummy app does).

### Linking back to the host app from engine views

Use `tc_host_root_path` (not a hardcoded path) to link back to the host application: it is `main_app.root_path`, or `/` when the host has no root route (a freshly generated app doesn't):
```erb
<%= link_to "App ↗", tc_host_root_path %>
```

## Code Style

RuboCop with `rubocop-rails-omakase` (Rails official style). Ruby 3.4 (`.ruby-version`); the gem supports 3.3+.

## Packaging

- `tudla_accounting.gemspec` lists only what host apps need at runtime (Rails, pg, tailwindcss-rails, importmap/stimulus, money-rails, ancestry, csv, roo). The Solid gems and test tools are in the `Gemfile`, for the dummy app and the suite; don't add them back to the gemspec.
- Record user-facing changes in `CHANGELOG.md` under "Unreleased".
- CI (`.github/workflows/ci.yml`) runs RuboCop, the suite against PostgreSQL and `gem build --strict`. `spec/dummy/config/database.yml` reads `DATABASE_HOST`/`DATABASE_USERNAME`/`DATABASE_PASSWORD` (defaulting to the Docker `db` service).
