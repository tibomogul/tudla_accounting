# Stimulus Setup for Dummy App

**Date:** 2026-04-11
**Status:** Approved

## Summary

Add `stimulus-rails` as a development dependency and configure Stimulus in the dummy app using the standard `stimulus:install` generator. The engine itself does not bundle Stimulus — it assumes the host application provides it.

## Gemspec Change

Add to `tudla_accounting.gemspec` alongside existing dev dependencies:

```ruby
spec.add_development_dependency "stimulus-rails"
```

No changes to runtime dependencies.

## Setup Steps

Executed inside the Docker container:

1. `bundle install` — picks up the new gem
2. `docker compose exec rails bash -lc 'cd spec/dummy && bin/rails stimulus:install'` — runs the generator from the dummy app root

## Generator Output

The `stimulus:install` generator produces exactly what it would in a standalone Rails 8 app:

- Pins `@hotwired/stimulus` and `stimulus-rails` in `spec/dummy/config/importmap.rb`
- Creates `spec/dummy/app/javascript/controllers/application.js`
- Creates `spec/dummy/app/javascript/controllers/index.js`
- Appends stimulus bootstrap import to `spec/dummy/app/javascript/application.js`

## Engine Boundary

No engine source files are modified. The engine's views may use `data-controller` attributes freely. Stimulus availability is treated as a host-app concern, consistent with how the engine treats Turbo/Hotwire.
