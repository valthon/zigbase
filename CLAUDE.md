# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ZigBase is a single-binary, PocketBase-inspired (not API-compatible) backend in **Zig 0.16**, backed by an embedded SQLite (vendored amalgamation) and the `zap`/facil.io HTTP server. It is **two things at once**:
- A standalone server binary (`zigbase serve`) with collections/records, a typed query API (filter/sort/expand), per-collection access rules, argon2id+JWT auth, OAuth2+PKCE, realtime over WebSocket, local file storage, and an embedded admin SPA at `/_/`.
- An **embeddable Zig framework**: consumers `zig fetch --save` it, `@import("zigbase")`, and configure `zigbase.App(.{...})` with comptime hooks, custom routes, scheduled jobs, plugins, a comptime schema, and migrations. See `docs/framework.md`.

Linux and macOS only (the HTTP server depends on facil.io). No Windows build.

## Toolchain & commands

All tools are pinned in `mise.toml` (Zig 0.16.0, Python 3.13, Node 24). Either `eval "$(mise activate bash)"` once, or prefix every command with `mise exec <tool> --`. The exact Zig version matters; another 0.16.x will not necessarily work.

```sh
mise exec zig@0.16.0 -- zig build                    # build -> zig-out/bin/zigbase
mise exec zig@0.16.0 -- zig build test --summary all  # all Zig unit tests
mise exec zig@0.16.0 -- zig build run -- <args>       # run the binary via the build system
```

CLI subcommands: `serve`, `migrate`, `superuser create --email … --password …`, `help`. For **local plain-HTTP development you must pass `--insecure-cookies`** or the admin-UI auth cookie won't be stored (cookies are `Secure` by default). The default bind is `127.0.0.1` (loopback); `--http-host 0.0.0.0` exposes all interfaces. A random JWT secret is auto-generated and persisted under the data dir on first run if `ZIGBASE_JWT_SECRET` is unset.

### Tests — there are two suites, both run in CI (`.github/workflows/ci.yml`)

1. **Zig unit tests** (`zig build test`). **Caveat:** `zig build test` prints a spurious `failed command: …` line even when everything passes; the authoritative signal is the `Build Summary: N/N tests passed` line (hence `--summary all`). To run the suite against a fresh tree, build the test binary directly. There is no per-test filter wired into `build.zig`.
2. **Python/Playwright "browser" suite** (`tests/admin/`) + a live SMTP-TLS test (`tests/smtp/`). These build the binary, launch a real server, and drive the admin SPA with a headless Chromium. Run one:
   ```sh
   mise exec python@3.13 -- python -m pytest tests/admin/test_schema.py::test_edit_rules_lock_toggle -q
   ```
   Run the whole suite in parallel with `-n auto` (pytest-xdist) — the harness is parallel-safe (each server binds its own free port + tempdir): `mise exec python@3.13 -- python -m pytest tests/admin -q -n auto`. `tests/smtp` stays serial (it binds a fixed TLS port). `tests/admin/conftest.py` is the harness (it builds + launches the server with `--insecure-cookies`). **Unit tests passing does NOT mean the browser suite passes** — behavior that only manifests end-to-end (admin UI, secure defaults, realtime, access rules) is caught only here. Run the relevant `tests/admin/` test locally after any change touching those areas; a green `zig build test` has repeatedly hidden real regressions that the `browser` CI job then failed on.

The example apps are also built in CI (the `examples/plugins` frontend must be `npm run build`-ed before its Zig build, since it embeds `frontend/dist`).

## Architecture (the parts that span multiple files)

**Library/binary split.** `build.zig` compiles `src/root.zig` into the `zigbase` module (links libc, compiles the vendored SQLite, imports `zap`); `src/main.zig` is a ~3-line consumer that calls `zigbase.App(.{}).runCli(init)`. Everything real lives in the library module.

**`src/root.zig` is both the public API surface AND the unit-test root.** Its `test { _ = @import("…"); }` block references every internal file so their `test {}` blocks are discovered. **A new `src/*.zig` file's tests will not run until it is added to that block.** `root.zig` also re-exports every type a framework consumer must be able to name (e.g. `App`, `RecordEvent`, `Storage`, `Mailer`, `Migration`, `Db`).

**`src/framework.zig` — `App(comptime cfg)` is a comptime application builder.** Config keys (`hooks`, `routes`, `cron`, `onError`, `storage`, `mailer`, `collections`, `migrations`, `pools`, `static_files`) are assembled and validated at compile time — an unknown key, a typo'd hook phase, a wrong-typed handler, or a bare-tuple `.migrations` is a `@compileError`, never a runtime failure. `runCli` parses argv and starts the server with the assembled extensions.

**Request lifecycle.** `server.zig` (zap listener) → `router.zig` → `api/*.zig` handlers (`records`, `collections`, `auth`, `oauth`, `files`, `health`). Record reads/writes go through `records.zig` and the curated `data.zig` facade (which is also what hooks/custom routes get). The query string is parsed by `query/` (lexer → parser → compiler) into **parameter-bound** SQL; identifiers (table/column/index/alias) are gated through `schema.isValidIdentifier` before interpolation — see `docs/security-audit.md` for the full threat model.

**Database connection model (`db.zig`).** A pool of warm reader connections plus a single writer guarded by a mutex; WAL mode. Hook/job/route code obtains a `Data`/`Db` from the pool. `before`-hooks on the HTTP create/update/delete path run *inside* the write transaction — hook writes via `ctx.records()` commit or roll back atomically with the triggering write; use `after`-hooks for side effects that must run only on success. Hook record mutations **must** allocate with `ev.arena` (the request-scoped arena that owns `ev.record`), never `ev.app.allocator`.

**Schema & provisioning (`schema.zig`, `provision.zig`, `ddl.zig`, `migrations.zig`).** A comptime `.collections` literal is lowered by `provision.buildCollections` and provisioned at startup (create-missing + additive field-add + relation-by-name resolution). **Non-additive changes (rename/drop/retype) are detected, logged, and skipped** — they need an explicit `.migrations` entry. **Stable field ids:** each field carries an 8-char *stable field id* (FNV hash of
collection+field) used to match columns across additive rebuilds (`ddl.rebuildPlan`
matches old/new fields by id, preserving data through a table rebuild). The **physical
SQLite column is named by the human field name**, so a raw-SQL migration can
`CREATE INDEX ON posts(status)` directly, and the comptime `.indexes` key indexes
provisioned columns by field name. Migrations remain the escape hatch for tables the
migration itself owns and for non-additive DDL the provisioner won't perform.

**Access rules (`rules.zig`) are safe-by-default (since v0.4.0).** A blank rule — `null` **or** `""` — means **Locked (superusers only)**. The explicit sentinel **`"@public"`** is the only allow-all; `provision.zig` logs a startup warning for every `@public` rule. Any other string is an expression evaluated per record. Rule parse errors fail **closed** (500, the write never runs).

**Events/hooks (`events.zig`).** `RecordEvent` / `ErrorEvent` / `JobEvent`. The `Dispatch` is built at comptime from `cfg.hooks`. Realtime (`realtime/`) re-applies each collection's `viewRule` per record on delivery; delete events authorize against a pre-delete snapshot.

**Embedded admin UI.** `src/admin.zig` serves the SPA whose source is `src/admin/app.js` (Preact via htm, `@embedFile`-d into the binary — there is no build step for it; edit `app.js` directly and rebuild the binary). Elements carry `data-test=…` hooks the Playwright suite drives. A consumer's own frontend is embedded separately via `build.zig`'s `embedStaticDir` (Vite/Astro `dist` → a generated `static_assets.zig` manifest with CRC32 ETags).

**Pluggable backends.** `files/storage.zig` (`Storage` vtable; only local-disk ships) and `mail/mailer.zig` (`Mailer` vtable; Log + SMTP with STARTTLS/implicit-TLS). Consumers swap them via `App(.{ .storage = T, .mailer = T })`.

## The three examples are a deliberate complexity ladder

`examples/blog` (bare packaging proof — one hook), `examples/golfsim` (a realistic app — computed/validating hooks, business routes, cron, file fields, realtime), `examples/plugins` (the advanced comptime surface — custom storage+mailer plugins, comptime schema, explicit migrations, embedded frontend). Each is a standalone consumer package with a path dependency on the repo root and its own vendored `zig-pkg/zap` (do not edit vendored deps). Keep blog the simplest and plugins the most advanced when changing them.

## Conventions that bite

- **Keep published docs and examples in sync with every change.** The repo has a parallel published-docs mirror under **`site/src/content/`** (Astro). Two files (`changelog.md`, `known-limitations.md`) are **generated** from their canonical root files (`CHANGELOG.md`, `KNOWN_LIMITATIONS.md`) by `site/scripts/gen-docs-mirror.mjs`, which runs automatically on `npm run dev`/`build` — edit the canonical file and the mirror follows; never hand-edit those two mirrors (they're gitignored build artifacts). The remaining `docs/*.md` mirrors under `site/src/content/docs/` are still **hand-synced** (single-sourcing them is tracked as follow-up work) — it is easy to update `docs/` and forget the site, which then publishes stale/wrong guidance. `.github/pull_request_template.md` carries the required sync checklist. `docs/superpowers/` is a historical design archive — do **not** rewrite it. Build the site with `cd site && npm run build` when docs change.
- The scheduler is single-process; cron is UTC, numeric-only, minute-granularity, and ANDs day-of-month with day-of-week.
- **Never edit `CHANGELOG.md` directly.** Add a fragment file `changelog.d/<slug>.md` for your change — body is one or more `### <Section>` headings (each with bullet lines); a single fragment may populate multiple sections. Recognized sections, in emit order: **Breaking, Features, Fixes, Changed, Performance, Deprecated, Removed, Security, Internal** (any other `### <name>` fails the build). The changelog is consumer-facing: the first eight sections are for **user-visible** changes; **Internal** (rendered last) is for contributor-facing changes with no consumer impact (build/CI, tests, refactors, tooling, the release/changelog process itself) — *would a user notice → a consumer section; only contributors notice → Internal; nobody needs it recorded → no fragment.* See `changelog.d/README.md`. This keeps parallel PRs from conflicting on the shared changelog; the fragments are aggregated per section into a release block and deleted at release time.
- **Sharpening rhythm & house API conventions.** Periodic "sharpening" audits sweep the config/API surface; fixes land as dedicated streams (see docs/superpowers/plans). The standing conventions they enforce: every list endpoint returns `{items}`; side-effect success = `204`; pagination = the records cursor vocabulary (`cursor`/`limit`, `nextCursor`/`hasNext`); URL segments are dash-case; config planes follow the assignment rule in docs/framework.md §3 (comptime = structure, env = deploy-varying, build flag = binary cost); optional subsystems must be comptime-gated (no unconditional fn-pointer registration — CI enforces via scripts/check-gating.sh); `tests/admin/test_docs_parity.py` fails on config-key-table or env-table drift. New endpoints/keys MUST follow these or update them deliberately.

## Releasing

`scripts/release.sh [--publish]` reads the version from `build.zig.zon`, **assembles the `changelog.d/` fragments** into the changelog (via `scripts/assemble-changelog.sh`, see below), cross-compiles 4 targets (`{x86_64,aarch64}-{linux-musl,macos}`), tars them with `SHA256SUMS`, and (`--publish`) runs `gh release create v<version>`. A release bumps the version in **`build.zig.zon`** (which drives the build-time-derived `site/src/config/site.ts` via `serverVersion()`) and **`KNOWN_LIMITATIONS.md`**; also grep `README.md` for any hardcoded version reference. The TS SDK (`clients/typescript`) is versioned **independently** (its own `package.json` + `CHANGELOG.md`, published on a `client-v*` tag — see `clients/typescript/RELEASING.md`), so a coupled release bumps it separately. Breaking changes pre-1.0 bump the minor (0.x.0). `gh pr edit` is broken on this repo — use `gh api -X PATCH` to edit a PR.

**Required: review the assembled changelog for internal consistency before opening the release PR.** Read every bullet — not just the section counts. The core defect to remove: a `Fixes`/`Changed`/`Breaking` bullet whose subject was *introduced in this same release*. A bug in a feature that never shipped is invisible to consumers, so the entry is dev-internal noise — fold it into that feature's own `Features` bullet (which should describe the correct final behavior) or drop it, rather than narrating a mid-development bug as a fix. Verify each questionable subject against the previous release tag: `git cat-file -e v<prev>:<path>` / `git show v<prev>:<file> | grep …` — absent at the prev tag ⇒ new this release ⇒ same-version noise; present ⇒ legit consumer-facing entry. Also merge cross-section duplicates (the same change written in both `Features` and `Fixes`).

`scripts/assemble-changelog.sh [<version> [<date>]] [--dry-run]` parses every `changelog.d/*.md` fragment, splits each on its `### <Section>` headings, aggregates the bullets per section across all fragments (canonical order: Breaking, Features, Fixes, Changed, Performance, Deprecated, Removed, Security, Internal; empty sections omitted), and inserts a new `## [<version>] - <date>` block (below `## [Unreleased]`, above the prior version) into `CHANGELOG.md`; the site mirror is regenerated from it at build time. Then `git rm`s the consumed fragments. It fails loudly with no fragments or an unknown `### <name>` section; `release.sh` skips it (not an error) when the changelog is already assembled. `--dry-run` prints the assembled section without touching any file. Don't run it in a feature PR — only add a fragment.
