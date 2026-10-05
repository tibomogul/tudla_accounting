# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

TudlaAccounting is a **Rails 8.1 mountable engine** with namespace isolation (`TudlaAccounting::`) and the Solid trifecta (Solid Queue, Solid Cache, Solid Cable), Tailwind CSS v4, and Importmap Rails.

## Commands

All commands run inside the Docker container:

```bash
docker compose exec rails bash -lc 'RAILS_ENV=test bundle exec rspec'                            # Run all specs
docker compose exec rails bash -lc 'RAILS_ENV=test bundle exec rspec spec/integration/solid_stack_spec.rb'  # Run single spec file
docker compose exec rails bash -lc 'bundle exec rubocop'                                          # Lint
docker compose exec rails bash -lc 'bundle exec rubocop -a'                                       # Auto-fix lint
docker compose exec rails bash -lc 'bin/setup'                                                    # First-time DB setup + dev server deps
docker compose exec -d rails bash -lc 'bin/dev'                                                   # Start dev server (Foreman: web + css + worker)
```

> **Note:** Always prefix `bundle exec rspec` with `RAILS_ENV=test`. The container has `RAILS_ENV=development` set in its environment, which overrides the `||=` default in `rails_helper.rb`.

## Architecture

This is a **Rails engine gem** (not a standalone app). All application code lives under the `TudlaAccounting::` namespace via `isolate_namespace TudlaAccounting` in `lib/tudla_accounting/engine.rb`.

- `lib/tudla_accounting.rb` — main entry point, requires Solid gems, Tailwind, Importmap
- `lib/tudla_accounting/engine.rb` — engine configuration with namespace isolation
- `spec/dummy/` — full Rails 8.1 app used for testing the engine (has its own config, routes, db); uses **Tailwind CSS v4** and **DaisyUI** for styling
- Engine is mounted at `/tudla_accounting` in the dummy app's routes

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

### Ancestry

`has_ancestry` must specify `ancestry_format: :materialized_path2` whenever the migration declares `null: false, default: "/"` on the ancestry column. The ancestry 5.x default format is `:materialized_path`, which uses `nil` for the root and crashes against a NOT NULL column.

## Testing Gotchas

- Use `stub_const` for inline job classes in specs (Solid Queue requires named classes)
- SolidCache hashes keys internally — don't query the DB by raw key name
- Use `TudlaAccounting::Engine.routes.url_helpers` for engine route helpers in specs
- Use `main_app.` prefix for host app routes within engine context
- FactoryBot factories go in `spec/factories/`, auto-loaded via engine initializer
- `spec/integration/posting_concurrency_spec.rb` turns off transactional tests and uses real threads and PostgreSQL row locks; it deletes its own data afterwards. Any spec that holds a lock in a thread must release it in an `ensure`, or the cleanup blocks forever
- PostgreSQL triggers (`TudlaAccounting::DatabaseProtection`) refuse updates and deletes of posted entries and their lines. Specs that need to tamper with posted rows (or clean them up outside a transaction) must wrap it in `TudlaAccounting::DatabaseProtection.allowing_posted_changes { ... }`. `rails_helper` installs the triggers before the suite, since `schema.rb` can't hold them
- `spec/rails_helper.rb` adds the engine's `db/migrate` to `DatabaseTasks.migrations_paths` so `maintain_test_schema!` sees engine migrations as applied; if specs report pending migrations after a schema change, rebuild the test DB (`RAILS_ENV=test bin/rails db:drop db:create db:schema:load`)

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

Use `main_app.root_path` (not a hardcoded path) to link back to the host application:
```erb
<a href="<%= main_app.root_path %>">App ↗</a>
```

## Code Style

RuboCop with `rubocop-rails-omakase` (Rails official style). Ruby 3.3.4.
