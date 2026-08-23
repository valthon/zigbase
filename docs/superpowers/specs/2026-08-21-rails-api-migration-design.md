# Rails API migration skill — design

**Date:** 2026-08-21
**Status:** Approved by the AI-agents program for implementation
**Program:** [ZigBase AI-Agents Program](2026-08-08-ai-agents-program-design.md), migration family
**Issue:** [#374](https://github.com/valthon/zigbase/issues/374)
**Baseline:** `origin/main` @ `46c00d44`

## Goal

Instantiate the migration family for Rails without waiting on Rails presentation support in
Zigapagos. The program gated "Rails" on advanced Zigapagos integration because a typical Rails
application ships its own frontend. That gate constrains the *presentation* half only. This
subproject deliberately scopes to the backend half — hence the `-rails-api` name — and ships a
skill that refuses to imply it migrated anything a browser renders.

## Why Rails is not another Laravel

Laravel and Go shipped as guide-plus-skill instances because their discovery traps are readable
from source. Rails resists that. Effective routes come from a DSL evaluated at boot, associations
and validations are declared through metaprogramming, `default_scope` silently filters every read
including the one an exporter would use, Active Storage keeps blob bytes outside the row that names
them, and `encrypts` makes a column unreadable without the application's key. Reading
`config/routes.rb` and `db/schema.rb` produces a plausible and wrong inventory.

Rails is therefore the second flagship-grade instance after PocketBase: it gets an offline
converter, a committed fixture, deterministic tests, and a graded agent-eval scenario, not just a
guide.

## Observed versus inferred

The converter never parses Ruby. Source truth is produced in two clearly separated tiers.

**Observed.** A small extractor runs inside the application under `bin/rails runner` and dumps
what the booted framework actually knows: the route set, model reflections, validators, enums,
`default_scope` presence, encrypted attribute names, the connection's real column types, and row
counts. Every record it emits is stamped `"source": "observed"` together with the Rails and Ruby
versions that produced it.

**Inferred.** When the application cannot be booted, a documented static fallback reads
`db/schema.rb` and `config/routes.rb` and stamps every record `"source": "inferred"`. The converter
refuses to promote an inferred record to observed, and the skill's completion contract refuses to
describe an inferred inventory as observed behavior.

## Deliverables

1. **`docs/migrate-rails-api.md`** — the canonical guide: freeze, observed inventory, schema and
   authorization mapping, deterministic extraction, HTTP parity, rehearsal, cutover, rollback, and
   the API-only scope gate.
2. **`skills/zigbase-migrate-rails-api/`** — the installable skill over byte-synced references.
3. **`tools/rails/export_source.rb`** — the observed-metadata extractor.
4. **`tools/rails/rails2zb.py`** — the offline converter: `inventory`, `extract`, `install-files`.
5. **A committed synthetic Rails 8 API fixture** — generated once from a real Rails application and
   frozen; CI never installs Ruby.
6. **`tests/rails/`** — deterministic converter tests against that fixture.
7. **`evals/agents/scenarios/rails-api/` and `evals/agents/graders/rails_api.py`** — the graded
   unattended migration scenario with positive and one-failure-per-grade fixtures.

## The scope gate

The skill may not report completion until one of two conditions is recorded:

1. the source exposes no user-facing Rails presentation surface — no view templates, no
   browser-rendered routes, no Turbo or Stimulus asset pipeline in the request path; or
2. the operator explicitly selected backend-only migration and the frontend is recorded as retained
   and out of scope.

When view or browser routes exist, the skill reports them as an inventory finding with its
disposition set to retained, and never as migrated. The handoff names the retained frontend
explicitly. Pairing a retained or replacement frontend is the
[Zigapagos pairing skill](../../zigapagos-pairing.md)'s job, not this one's.

## Fidelity boundaries

These are recorded as findings requiring a durable decision, never converted silently:

- `default_scope` — the exporter reads through `unscoped`; a scoped read is a data-loss bug.
- Active Record encryption — ciphertext never migrates; the decision is re-key or retire.
- Polymorphic associations and single-table inheritance — no automatic collection shape exists.
- Database triggers and raw SQL — behavior lives outside the schema the converter can read.
- Password hashes — `has_secure_password` bcrypt imports through `--legacy-hashes bcrypt` with
  rehash-on-login; every other algorithm requires a reviewed reset.
- Sessions, `secret_key_base`, signed and encrypted cookies, and API tokens never migrate.

## Non-goals

ERB, Haml, Slim, Turbo, Stimulus, Sprockets, Propshaft, and Rails-managed assets are out of scope.
The subproject does not claim arbitrary gems or Ruby metaprogramming convert mechanically, and it
does not block on Zigapagos Rails presentation support.
