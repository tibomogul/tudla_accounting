# Stimulus Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `stimulus-rails` as a development dependency and configure Stimulus in the dummy app using the standard `stimulus:install` generator.

**Architecture:** `stimulus-rails` is declared as a gemspec development dependency only — never a runtime engine dependency. The generator runs inside the Docker container from the dummy app root, producing the canonical Rails 8 Stimulus file layout under `spec/dummy/`.

**Tech Stack:** Rails 8.1, stimulus-rails, importmap-rails, Docker Compose

---

### Task 1: Add stimulus-rails to gemspec

**Files:**
- Modify: `tudla_accounting.gemspec`

- [ ] **Step 1: Add the development dependency**

Open `tudla_accounting.gemspec` and add `stimulus-rails` alongside the existing dev dependencies (after `selenium-webdriver`):

```ruby
  spec.add_development_dependency "selenium-webdriver"
  spec.add_development_dependency "stimulus-rails"
  spec.add_development_dependency "debug"
```

- [ ] **Step 2: Run bundle install inside Docker**

```bash
docker compose exec rails bash -lc 'bundle install'
```

Expected: output ends with `Bundle complete!` and includes `stimulus-rails` in the installed gems. No errors.

- [ ] **Step 3: Commit**

```bash
git add tudla_accounting.gemspec Gemfile.lock
git commit -m "Add stimulus-rails as development dependency"
```

---

### Task 2: Run stimulus:install generator in dummy app

**Files (created/modified by generator):**
- Modify: `spec/dummy/config/importmap.rb`
- Modify: `spec/dummy/app/javascript/application.js`
- Create: `spec/dummy/app/javascript/controllers/application.js`
- Create: `spec/dummy/app/javascript/controllers/index.js`

- [ ] **Step 1: Run the generator from the dummy app root**

```bash
docker compose exec rails bash -lc 'cd spec/dummy && bin/rails stimulus:install'
```

Expected output (approximately):

```
      append  app/javascript/application.js
      create  app/javascript/controllers/application.js
      create  app/javascript/controllers/index.js
      append  config/importmap.rb
```

- [ ] **Step 2: Verify importmap.rb was updated**

```bash
docker compose exec rails bash -lc 'cat spec/dummy/config/importmap.rb'
```

Expected: file now contains pins for `@hotwired/stimulus` and `stimulus-rails`, e.g.:

```ruby
pin "application"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin "controllers", to: "controllers/index.js"
pin "controllers/application", to: "controllers/application.js"
```

- [ ] **Step 3: Verify controller files were created**

```bash
docker compose exec rails bash -lc 'cat spec/dummy/app/javascript/controllers/application.js'
docker compose exec rails bash -lc 'cat spec/dummy/app/javascript/controllers/index.js'
```

Expected: `application.js` exports a `Stimulus.Application` instance; `index.js` imports and registers controllers via eager/lazy loading.

- [ ] **Step 4: Verify application.js was updated**

```bash
docker compose exec rails bash -lc 'cat spec/dummy/app/javascript/application.js'
```

Expected: file now imports controllers:

```js
import "controllers"
```

- [ ] **Step 5: Commit**

```bash
git add spec/dummy/config/importmap.rb \
        spec/dummy/app/javascript/application.js \
        spec/dummy/app/javascript/controllers/application.js \
        spec/dummy/app/javascript/controllers/index.js
git commit -m "Configure Stimulus in dummy app via stimulus:install"
```
