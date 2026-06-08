# ZigBase — Architecture & Design

**Date:** 2026-06-08
**Status:** Approved (architecture); per-sub-project specs to follow
**Goal:** A usable, PocketBase-*inspired* backend-as-a-service implemented in Zig 0.16.0, shipped as a single static binary.

---

## 1. Overview & Goals

ZigBase is a single-binary backend-as-a-service in the spirit of PocketBase: an embedded
SQLite database, dynamic user-defined collections with a typed schema, a REST CRUD API with
a filter/sort/pagination query language, record-level access rules, authentication
(password + OAuth2), realtime subscriptions, file storage, schema migrations, and an admin
web UI.

We are **PocketBase-inspired, not PocketBase-compatible**: we reuse the proven concepts but
design our own clean API. The official PocketBase SDKs are *not* a compatibility target.

Primary objective: reach a genuinely usable product. Feature parity with PocketBase grows
over time. We build the full system in dependency order; every sub-project below is committed
scope, not optional.

### Non-goals (for now)
- Drop-in PocketBase API/SDK compatibility.
- A JavaScript hooks/plugin runtime (PocketBase's `pb_hooks`). May revisit later.
- Image thumbnail generation, S3 storage backends (interface designed for it; local-only first).
- Clustering / horizontal scale. Single-node only.

---

## 2. Locked Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language / toolchain | Zig **0.16.0**, pinned via `mise` (`mise.toml`) | User requirement |
| HTTP server | **zap** (facil.io wrapper) | User choice; **we fork & patch zap** if 0.16 compat / SSE / multipart fall short — no std.http fallback |
| SQLite access | **Vendored amalgamation** (`vendor/sqlite/sqlite3.c`) via `@cImport` | Zero dependency/version risk, single static binary, full control |
| Database mode | SQLite **WAL** | Concurrent readers + single writer |
| JSON | `std.json` | In stdlib |
| Password hashing | `std.crypto.pwhash.argon2` (argon2id) | Modern, in stdlib |
| Tokens | Self-issued **JWT HS256** (`std.crypto`), salted per-record `tokenKey` | Password change invalidates issued tokens (PB-style) |
| OAuth2 outbound HTTP | `std.http.Client` | Needed regardless; stdlib |
| API style | PocketBase-*inspired*, our own clean REST design | User choice |
| Admin UI | Full SPA, built as the final sub-project | User choice |

---

## 3. Module Architecture

Each module has one clear purpose, a defined interface, and is independently testable.

| Module | Responsibility | Depends on |
|---|---|---|
| `main` / `cli` | Process entry; subcommands `serve`, `migrate`, `superuser create` | config, db, api |
| `config` | Load config from env + CLI flags + optional file; data dir, port, JWT secret, CORS | — |
| `db` | SQLite C-interop wrapper: open, prepared statements, row→struct mapping, transactions, connection pool (serialized writer + per-worker read connections in WAL); error mapping | (C) sqlite |
| `schema` | Collection definitions (name, type `base`/`auth`/`view`, fields, indexes, rules); maps a collection to its physical SQLite table; emits/applies DDL on collection create/update/delete; validates records against field schema | db |
| `records` | Generic record CRUD over a collection's table; JSON ↔ typed column (de)serialization; relation `expand` | db, schema |
| `query` | Parse the filter expression language (`a >= 10 && name ~ "x" \|\| b = false`), sort (`-created,name`), pagination (`page`/`perPage`), field selection; compile to **parameterized** SQL `WHERE`/`ORDER`/`LIMIT` | schema |
| `rules` | Per-request access rules (`listRule`, `viewRule`, `createRule`, `updateRule`, `deleteRule`); compile rule expression + request context (`@request.auth.id`, `@request.data.*`) into SQL constraints and/or pre-checks; `null` rule = superuser-only, `""` = public | query, auth |
| `auth` | Password hash/verify; JWT issue/verify; superusers; auth endpoints (auth-with-password, refresh, password-reset request/confirm, email verification) | db, schema |
| `oauth2` | Provider redirect → callback → token exchange → identity fetch → account create/link | auth, config |
| `realtime` | SSE: subscription registry, topic subscribe/unsubscribe, rule-filtered broadcast on record create/update/delete | api, rules, records |
| `files` | File-type fields stored on local FS (`storage/<collection>/<recordId>/<filename>`); multipart upload parsing; download endpoint with optional access token; pluggable storage interface (local now) | records, config |
| `migrations` | `_migrations` tracking table; ordered Zig migration functions; system-schema setup | db |
| `api` / `router` | zap routing; REST endpoints; request parsing; central JSON error envelope; CORS | all of the above |
| `admin` | Static SPA assets (final phase); embedded or served from disk; talks to the public API | api |

### Module boundary principle
Higher modules depend on lower ones; no cycles. `query`/`rules` compile to SQL strings + bound
parameters and never touch the network. `api` is the only module that knows about zap/HTTP.

---

## 4. Field Types

`text`, `number`, `bool`, `email`, `url`, `date`, `autodate` (auto-set created/updated),
`json`, `select` (single or multi, with allowed values), `relation` (to another collection,
single/multi, cascade options), `file` (single/multi, size/type limits), `editor` (rich text/HTML).

Each field type defines: SQL column affinity, validation rules, JSON (de)serialization, and
options schema.

---

## 5. Data Model

### System tables
- `_collections` — `id`, `name`, `type`, `schema` (JSON field defs), `listRule`, `viewRule`,
  `createRule`, `updateRule`, `deleteRule`, `indexes` (JSON), `options` (JSON), `created`, `updated`.
- `_superusers` — `id`, `email`, `passwordHash`, `tokenKey`, `created`, `updated`.
- `_migrations` — `id`, `name`, `applied_at`.
- `_settings` — app settings key/value (JWT secret may live here or in config).

### Collection tables
Each user collection becomes a physical table named after the collection, with system columns:
- `id` TEXT PRIMARY KEY (15-char random, URL-safe)
- `created` TEXT (RFC3339), `updated` TEXT
- one column per schema field.

**Auth collections** additionally carry: `email`, `passwordHash`, `tokenKey`, `verified`,
plus password-reset/verification bookkeeping as needed.

---

## 6. Concurrency Model

zap runs request handlers across multiple worker threads. SQLite is opened in **WAL** mode.

- **Writes** are serialized through a single write connection guarded by a mutex.
- **Reads** use a pool of read-only connections (one per worker, or a small pool), allowing
  concurrent reads alongside the single writer.
- The exact pool sizing and zap's threading/worker model are **validated in Sub-project 1**;
  the `db` interface (`acquireReader`/`acquireWriter`) hides the strategy from callers.

---

## 7. Security

- **SQL injection:** the `query`/`rules` compilers emit only parameterized SQL; user values are
  always bound, never interpolated. Identifiers (table/column names) come from validated schema,
  never raw input.
- **Passwords:** argon2id via `std.crypto.pwhash`.
- **Tokens:** JWT HS256 signed with app secret combined with the record's `tokenKey`; rotating a
  record's `tokenKey` (e.g. on password change) invalidates all previously issued tokens.
- **Access rules** are enforced on every record operation; default-deny (superuser-only) when a
  rule is `null`.
- **CORS** configurable; **rate limiting** is a later addition (noted, not in early scope).

---

## 8. Error Handling

A single JSON error envelope, returned for all API errors:

```json
{ "code": 400, "message": "Failed to create record.", "data": { "email": { "code": "validation_required", "message": "Cannot be blank." } } }
```

Zig error unions are mapped to `(http_status, error_code, message)` by a central renderer in `api`.
Validation failures populate the per-field `data` map.

---

## 9. Testing Strategy

TDD throughout (red → green → refactor).

- **Unit tests** (`test` blocks) per module: `db` round-trips, `schema` validation, `query`
  filter→SQL compilation (including injection-attempt cases), `rules` compilation, `auth`
  hash/verify and JWT issue/verify.
- **Integration tests:** a harness that boots the server on an ephemeral port against a temp data
  dir, drives it with `std.http.Client`, and asserts JSON responses end-to-end.
- `zig build test` runs the full suite.

---

## 10. Build & Distribution

- `build.zig` + `build.zig.zon` (pins zap; vendors SQLite amalgamation under `vendor/sqlite/`).
- `zig build` → static `zigbase` binary; `zig build test` → test suite.
- `mise.toml` pins Zig 0.16.0.

---

## 11. Sub-Project Roadmap

Each sub-project gets its own spec → implementation plan → build/test cycle. All are committed scope.

1. **Foundation** — build system, vendored SQLite, `db` layer (pool, statements, txns, mapping),
   zap server skeleton, `config`, `cli`, health endpoint, central error envelope, integration test
   harness. **Validates:** zap-on-0.16 build, zap SSE/streaming + multipart availability,
   concurrency/pooling model. (Fork/patch zap here if required.)
2. **Collections & schema engine** + system tables + migrations core.
3. **Records CRUD + query/filter language + REST endpoints.**
4. **Access rules.**
5. **Auth** — password + JWT + superusers + auth endpoints.
6. **OAuth2.**
7. **Realtime (SSE).**
8. **File storage.**
9. **Admin SPA.**

---

## 12. Open Risks (validated early, in Sub-Project 1)

1. **zap on Zig 0.16.0** — brand-new compiler; may require a pinned commit or a fork. Mitigation:
   **we fork and patch zap** as needed.
2. **zap SSE/streaming** (realtime) and **multipart** (uploads) — if unsupported, patch zap or
   hand-roll chunked responses / multipart parsing.
3. **zap threading vs SQLite pooling** — confirm worker model; finalize pool strategy behind the
   `db` interface.
