# ZigBase — Post-v0.1 Functionality Ideas (Roadmap Ideation)

**Status:** Ideation / not committed scope. **Date:** 2026-06-09.

This document is a roadmap-discussion artifact: an opinionated, prioritized set of
features ZigBase should consider building *on top of* the v0.1 line (Foundation →
Collections → Records/Query → Access Rules → Auth → OAuth2 → Realtime → File storage →
Admin SPA → **embeddable comptime framework**). It is grounded in the *actual* current
codebase, not a generic BaaS feature dump. The framing matters: ZigBase already has a
comptime framework, a pluggable mailer, comptime storage/mailer plugins, comptime pool
levers, a reader-connection pool, and schema migration with table rebuilds. The ideas
below are the **next layer** built on those seams — not a re-implementation of them.

## Where ZigBase actually is today (grounding against current `main`)

What exists in `src/` right now:

- **Collections + schema engine** (`schema.zig`, `collections.zig`, `ddl.zig`) with field
  types `text, email, url, editor, date, autodate, bool, number, json, select, relation,
  file`; per-field `required`/`unique`/`hidden`; collection types `base`/`auth`/`view`;
  `indexes` stored as JSON on `_collections`. `ddl.zig` already emits CREATE/index DDL and a
  **`rebuildPlan`** (create-temp → copy → drop → rename + ALTER) for schema changes.
- **Schema migrations** (`migrations.zig`) — an idempotent, ordered `_migrations` ledger for
  *system* schema applied on startup (`migrate` CLID + auto on `serve`).
- **Records CRUD + a real query compiler** (`records.zig`, `query/`) that compiles a
  filter/sort/expand language to **parameterized** SQL with relation joins. Every user value
  is bound, never interpolated. `viewRule` is enforced on expand.
- **Access rules** (`rules.zig`) compiled to guarded `SELECT 1`/`WHERE` fragments. Policy is
  `null` = superuser-only, `""` = public, expression = `check`.
- **Auth** (`auth.zig`, `api/auth.zig`, `jwt.zig`, `crypto.zig`): argon2id passwords (run off
  the writer lock), HS256 JWT salted with a per-record `tokenKey` (so password change revokes
  tokens), superusers, constant-time login-miss, password-reset + email-verification flows.
- **OAuth2 PKCE** (`oauth/`) for google/github/microsoft/discord.
- **Realtime over WebSocket** (`realtime/{ws,hub,connection,protocol}.zig`) with rule-filtered
  broadcast on record mutations. `ws.broadcast(app, col, action, id, record)` publishes to a
  collection channel and a record channel via the reactor — the canonical *mutation seam*.
- **File storage** (`files/`) behind a backend-agnostic **`Storage` vtable**
  (`put`/`localPath`/`delete`/`deleteRecord`) with a `LocalStorage` impl; multipart parsing;
  short-lived file tokens; server-side MIME sniffing; `nosniff`/force-download hardening.
  `localPath` returning `null` for non-local backends is *already* designed in.
- **Pluggable Mailer** (`mail/mailer.zig`): a `Mailer` vtable (mirroring `Storage`) with two
  shipped backends — `LogMailer` (default; logs the message) and `SmtpMailer` (plaintext SMTP
  + optional AUTH LOGIN). It is **wired into `api/auth.zig`**: verification and password-reset
  tokens are delivered through `app.mailer.send(...)`. Config-driven: set `ZIGBASE_SMTP_HOST`
  to upgrade from log to SMTP with no code change.
- **Embeddable comptime framework** (`framework.zig`): `App(.{...})` returns a type whose
  comptime-resolved `dispatch` wires **record-lifecycle hooks** (before/after create/update/
  delete) plus `onAuth`, `onFileServe`, `onFileUpload`, `onBootstrap`, `onBeforeServe`,
  `onBeforeTerminate`, custom **routes**, and a **cron/interval/reactive scheduler**
  (`scheduler.zig` + `schedule.zig`) with backoff-retry. Ad-hoc work runs via `app.submit`.
  Unknown `cfg` keys are a *compile error*. `runCli` gives an embedding binary the same
  `serve`/`migrate`/`superuser`/`help` commands. Worked examples: `examples/blog` and
  `examples/golfsim`.
- **Comptime plugins + pool levers** (`framework.zig`): `App(.{ .storage = T, .mailer = T })`
  swaps the storage/mailer backend at comptime via a uniform `create`/`interface`/`deinit`
  contract; `.pools.readers` and `.pools.jobs` are comptime levers for the reader-pool cap and
  the scheduler worker pool.
- **Reader-connection pool** (`db.zig`): warm read-only SQLite connections kept for reuse
  (the perf commit cites ~2.5× list rps, p50 2.4ms→0.95ms). Writes remain serialized.
- **Embedded admin SPA** (`src/admin/`, preact+htm) served under `/_/`.
- **Sentry** error reporting (`report/sentry.zig`) gated by `ZIGBASE_SENTRY_DSN`.
- **Config** is a flat struct (`config.zig`) overridden by env/flags; `App` (`app.zig`) is the
  shared runtime handle (allocator, `std.Io`, `db.Pool`, secrets, optional `*Storage`,
  optional `*Mailer`).

Notable facts that shape the ideas below:

- **FTS5 is already compiled in** (`build.zig`: `-DSQLITE_ENABLE_FTS5`). Full-text search is a
  wiring exercise on top of the existing compiler — unusually cheap leverage, not yet exposed.
- **The vtable + comptime-plugin pattern is the established extension seam.** `Storage` and
  `Mailer` both follow it; S3, other mailers, and future backends slot in with **zero changes**
  to callers. Re-use this exact shape for new pluggables.
- **The mailer exists but `SmtpMailer` is plaintext-only** — no TLS/STARTTLS, no submission-port
  (465/587) support. That is the concrete remaining mailer gap, not "there is no mailer."
- The query compiler already does **relation joins** and emits parameterized SQL — projection,
  aggregation, FTS, soft-delete, and JSON-path filters all *extend* it rather than replace it.
- Everything is **single-binary, single-node, WAL SQLite** with a serialized writer + a warm
  reader pool. Scaling ideas must respect that (one writer) rather than fight it.
- The **scheduler already runs cron/interval/reactive jobs with backoff-retry**, so durable
  queues / webhooks / scheduled backups attach to an existing worker, not a greenfield one.

A recurring theme: ZigBase's differentiators are **comptime** (validate schema/rules/routes/
hooks at compile time, codegen typed records), **single static binary** (trivial edge deploy),
and **embeddability** (drop the whole BaaS into a larger Zig program — already real via
`App(cfg).runCli`). Several ideas below lean into those rather than chasing PocketBase parity
for its own sake.

The known gaps live in `KNOWN_LIMITATIONS.md`: no rate-limiting; SMTP has no TLS; no S3 (vtable
ready, no impl); no image transforms; admin UI has no logs/settings screens; the editor is a
plain textarea; the scheduler is single-process; no Windows build.

---

## Top 8 recommendations (the shortlist)

Ordered by leverage = (user/operator need) × (fit with current architecture) ÷ effort.

1. **Auth rate limiting + abuse throttling (S).** The single biggest *correctness/abuse* gap
   that remains. Login, password-reset-request, signup, email-verification-request, and the
   OAuth callback are all unthrottled today. Without this, any public deploy is a
   credential-stuffing and email-bomb target (and now that the mailer actually sends, the
   email-bomb risk is *real*, not just logged). Small, self-contained, attaches cleanly to the
   existing `onAuth` hook seam. Build first.

2. **SMTP TLS / STARTTLS + submission ports (S–M).** The mailer is wired and works against
   plaintext relays/dev sinks, but `SmtpMailer` deliberately ships **no TLS**, so it can't talk
   to real providers (Gmail/SES/Postmark on 465/587). This is the difference between "email
   works in dev" and "email works in production." Extends the existing `SmtpMailer` — no new
   abstraction.

3. **Full-text search via FTS5 (M).** FTS5 is *already compiled in*. Expose a `search=` query
   param (or a `~` extension) that maintains an FTS5 virtual table per opted-in collection via
   triggers and rewrites the query to a `MATCH` join with `ORDER BY rank`. Huge
   perceived-value/effort ratio; most SQLite-backed competitors bolt it on awkwardly.

4. **Batch / transaction endpoint (M).** A single `POST /api/batch` that runs N create/update/
   delete ops atomically on the serialized writer. SQLite + single-writer makes real ACID
   batches trivial here — a genuine differentiator over BaaSes that fake it. Unlocks
   offline-sync clients and multi-record forms.

5. **S3 storage plugin (M).** The `Storage` vtable and the comptime-plugin contract
   (`create`/`interface`/`deinit`) already exist with exactly the right shape, and `localPath`
   returning `null` for remote backends is already handled in the sendFile path. Ship an
   `S3StoragePlugin` selectable via `App(.{ .storage = S3StoragePlugin })` or config. Highest-
   value plugin to add; proves the plugin pattern generalizes beyond the shipped defaults.

6. **TOTP MFA + API keys / service tokens (M).** TOTP (RFC 6238) is pure `std.crypto` (HMAC-
   SHA1), no new deps. API keys give server-to-server callers a credential that isn't a user
   JWT. Together they move auth from "solid" to "I'd trust it for real accounts." Sequence after
   rate limiting (#1).

7. **`fields=` projection + ETags / optimistic concurrency (S–M).** `fields=` trims response
   payloads (the query layer already parses dotted field lists for sort/expand). ETag +
   `If-Match` on update gives lost-update protection for free off the existing `updated`
   timestamp. Cheap, broadly useful, expected of a serious API. Both are listed as deferred in
   `KNOWN_LIMITATIONS.md`.

8. **Comptime-typed collections → generated record structs (L, differentiator).** The signature
   ZigBase move, and the natural *next* step now that `App(cfg)` exists: a comptime schema
   definition that (a) compile-time-validates field/rule/index references and (b) codegens typed
   Zig record structs so embedding apps get `Post{ .title: []const u8 }` instead of
   `std.json.Value`. Nothing else in the BaaS space can do this. Larger effort; sequence after
   the operational gaps are closed.

**Why these eight:** #1–#2 finish making a public deployment *safe and fully functional* (the
mailer exists, but unthrottled + plaintext-only it's not production-grade). #3–#4 are
disproportionate-value wins enabled by choices already made (FTS5 compiled in, single writer).
#5–#7 are "serious BaaS" parity table-stakes with low-to-medium effort given existing
abstractions (the vtable/plugin pattern, the query compiler, `RequestContext`). #8 is the
long-game differentiator that justifies "why Zig" and builds directly on the comptime framework
already in `main`.

---

## Full catalog

Each idea: **What / Why / How it fits / Effort / Risk / Parity-or-Differentiator.**

### A. Auth & identity

#### A1. Rate limiting & abuse throttling — **Effort S, Risk Low, Parity**
- **What:** Per-IP and per-identity throttles on `auth-with-password`, password-reset-request,
  signup, email-verification-request, and the OAuth callback; configurable limits + lockout/backoff.
- **Why:** No throttling exists (per `KNOWN_LIMITATIONS.md`). Public deploys are open to
  credential stuffing and reset/verify email-bombing — and since the mailer now *actually sends*,
  the email-bomb cost is real. This is the #1 remaining "internet-facing" gap.
- **How it fits:** A small in-process token-bucket keyed by IP/identity, living in `App` (single
  node, so an in-memory map behind a mutex is sufficient — no Redis). Enforce in the `api/auth.zig`
  handlers, or attach via the existing **`onAuth` hook seam** in the framework dispatch. Add
  `ZIGBASE_RATE_*` config knobs. Optionally persist counters to a `_ratelimits` table so limits
  survive restart. Generalize later into reusable middleware any route can attach.
- **Risk:** Low. Watch for shared-NAT false positives (mitigate: identity-scoped limits for known
  users, IP-scoped for anonymous). Behind a proxy, read `X-Forwarded-For` carefully.
- **Depends on / ordering:** Foundational; build first. Unblocks safe rollout of A3/A4/A6.

#### A2. SMTP TLS / STARTTLS + transactional templates — **Effort S–M, Risk Low–Medium, Parity**
- **What:** Add TLS (implicit on 465) and STARTTLS (587) to the existing `SmtpMailer`; add
  editable, templated transactional emails for verification, reset, and (later) magic links.
- **Why:** The `Mailer` vtable and SMTP backend already exist and are wired into auth — but
  `SmtpMailer` is **plaintext-only by design**, so it can't reach Gmail/SES/Postmark. TLS is the
  one thing standing between "logs the token / talks to maildev" and "emails real users."
- **How it fits:** Extend `mail/mailer.zig`'s `SmtpMailer.send` with a TLS path over `std.Io`'s
  TLS (the connect→EHLO→AUTH→DATA flow is already there; wrap the stream). Keep `LogMailer` as the
  zero-config default. Store templates in a `_settings` row so the admin UI (D5) can edit them.
  No new abstraction — this *completes* the shipped one.
- **Risk:** Low–Medium. TLS/cert handling is fiddly; deliverability (SPF/DKIM) is operator config,
  not ours.
- **Depends on / ordering:** Independent; do early — prerequisite for A4 (magic links) reaching
  real inboxes.

#### A3. TOTP MFA — **Effort M, Risk Medium, Parity**
- **What:** Time-based one-time-password second factor (authenticator apps); enroll/verify/disable
  endpoints; recovery codes.
- **Why:** Expected of any auth system handling real accounts; cheap because it needs no new crypto deps.
- **How it fits:** TOTP is HMAC-SHA1 over a counter — entirely `std.crypto` (the same toolbox
  `crypto.zig`/`jwt.zig` already use). Store an encrypted TOTP secret + hashed recovery codes on
  auth records (new system columns, gated by a collection option). Add an `mfa` step between
  password verify and token issuance in `api/auth.zig`.
- **Risk:** Medium — secret storage must be encrypted at rest; clock-skew window handling;
  recovery-code UX. Don't lock users out.
- **Depends on / ordering:** After A1 (verification endpoints must be throttled).

#### A4. Magic-link / passwordless & one-time codes — **Effort S–M, Risk Low, Parity+Diff**
- **What:** Email a single-use login link or 6-digit code; no password required.
- **Why:** Lower-friction onboarding; increasingly the default for consumer apps. Reuses existing
  token machinery *and* the now-real mailer.
- **How it fits:** The JWT typed-token system already mints scoped tokens — add a `magic_link`
  type with a short TTL and single-use semantics (track jti in a `_used_tokens` table). Delivery
  goes through the existing `app.mailer.send(...)`.
- **Risk:** Low. Must be single-use and short-lived to avoid link-replay.
- **Depends on / ordering:** Mailer is already wired; A2 (TLS) is what gets these into real inboxes.

#### A5. API keys / service tokens — **Effort M, Risk Medium, Parity**
- **What:** Long-lived, revocable, scoped credentials for server-to-server callers (not a user JWT).
- **Why:** Backend integrations, cron jobs, CI shouldn't impersonate a user or hold a superuser
  password. Distinct identity class with its own permissions.
- **How it fits:** New `_api_keys` table (hashed key, scopes, optional collection allow-list,
  expiry). Recognize an `Authorization: Bearer zb_...` prefix or `X-API-Key` header in the auth
  resolver (`auth.authenticate`) and produce a `RequestContext` whose `is_superuser`/scope is
  derived from the key. The rules engine already keys off `RequestContext`, so enforcement is reused.
- **Risk:** Medium — scope model design; must hash-at-rest and show the secret only once.
- **Depends on / ordering:** After RBAC (A7) ideally, so scopes map to roles; can ship coarse first.

#### A6. Session management & token revocation — **Effort M, Risk Medium, Parity**
- **What:** List active sessions, revoke a single session, "log out everywhere"; refresh-token rotation.
- **Why:** Today the only revocation lever is rotating `tokenKey` (nukes *all* sessions). Users
  expect device-level control.
- **How it fits:** Add a `_sessions` table (record id, jti, device/UA, last-seen) and embed jti in
  the JWT. Revocation = delete the row; the auth resolver checks jti against a denylist (cache it
  in `App` to avoid a DB read on the hot auth path). Admin API + SPA tab to view/kill sessions.
- **Risk:** Medium — adds work to the hot auth path; cache carefully.
- **Depends on / ordering:** After A1. Synergizes with A5 (unified credential listing).
- **Status (0.10.0): shipped, opt-in.** `ctx.auth()` verbs, a REST surface
  (`GET`/`DELETE /api/collections/:col/auth/sessions[/:sid]`), and the TypeScript SDK
  (`listSessions`/`revokeSession`/`revokeAllSessions`) all ship. The default `session_store`
  is **still `.epoch`** (stateless, zero extra DB work) — per-device list/revoke requires
  opting into `.auth.session.store = .table` (one extra read per authenticated request). See
  [framework.md → Revoking sessions](framework.md#ctxauth--session-management) and
  [typescript-sdk.md → Sessions](typescript-sdk.md#sessions-listsessions--revokesession--revokeallsessions).

#### A7. RBAC / roles beyond superuser-vs-record — **Effort L, Risk Medium, Parity+Diff**
- **What:** Named roles/permissions; rules that reference `@request.auth.role`; per-collection role grants.
- **Why:** Real apps have editors/moderators/admins. Today it's binary superuser-or-record-owner,
  which forces awkward per-record rule gymnastics.
- **How it fits:** Add a `role`/`roles` concept to auth records and expose `@request.auth.role` in
  the rule language (the compiler already resolves `@request.auth.*` placeholders — extend that
  resolution). **Differentiator angle:** with comptime collections (D2), roles *and* the rules
  that reference them get validated at compile time.
- **Risk:** Medium — rule-language surface growth; migration of existing rules. Keep backward compatible.
- **Depends on / ordering:** After the query/rule placeholder layer is stable. Pairs with A5 scopes.
- **Status: deferred, by choice.** Equality-composition already works today with zero rule-grammar
  growth — put a `role` select field on the auth collection and reference it via
  `@request.auth.role = "editor"` (see [recipes.md → Global roles with a select
  field](recipes.md#recipe-global-roles-with-a-select-field-no-framework-rbac)). Per-account roles ship an
  ordered ladder via the tenancy system (`_memberships.role`, `@request.account.role`,
  `.abilities.min_role`). What's still missing is a **global** ordered comparison (`role >= editor`
  outside a tenancy scope) — that needs the rule-grammar growth this idea flags as its risk.
  Revisit post-1.0 if the select-field recipe proves insufficient in practice.

#### A8. More OAuth providers + generic OIDC — **Effort S each / M for generic, Risk Low, Parity**
- **What:** Apple, GitLab, Twitch, Facebook, etc., plus a **generic OIDC** provider configured by
  discovery URL.
- **Why:** Provider coverage is a checkbox buyers look for; generic OIDC covers Auth0/Okta/Keycloak in one.
- **How it fits:** `oauth/providers.zig` is already a table of `Provider` structs with a
  `ProviderMapping`. Adding a provider is a few lines. Generic OIDC = fetch
  `.well-known/openid-configuration` at config time and populate the same struct dynamically; map
  standard claims (`sub`/`email`/`name`/`picture`).
- **Risk:** Low (table-driven). Apple is the fiddly one (client-secret-as-JWT, form_post).
- **Depends on / ordering:** Independent; pick off opportunistically.
- **Status (0.10.0): generic OIDC shipped** (`.discoveryURL`, resolved once at startup,
  fail-closed) — see [framework.md → Generic OIDC
  discovery](framework.md#oauth2-providers-authoauth2). Named presets beyond the existing
  `google`/`github`/`microsoft`/`discord` table (Apple, GitLab, Twitch, Facebook, …) remain
  opportunistic — pick off as requested.

---

### B. Data & query

#### B1. Full-text search (FTS5) — **Effort M, Risk Low–Medium, Parity (cheaply)**
- **What:** A `search=` param (or `~~` operator) that does real ranked full-text search over chosen
  text fields of a collection.
- **Why:** **FTS5 is already compiled into the binary** (`-DSQLITE_ENABLE_FTS5`) — nearly-free
  leverage that most SQLite BaaSes never wire up cleanly.
- **How it fits:** When a collection opts in (`options.fts = ["title","body"]`), `ddl.zig` creates a
  contentless FTS5 virtual table + triggers to keep it in sync on insert/update/delete (it already
  emits CREATE/index DDL and rebuild plans). The query compiler gains a branch that, for `search=`,
  emits `JOIN <col>_fts ON ... WHERE <col>_fts MATCH ?` and can `ORDER BY rank`. Optional
  snippet/highlight.
- **Risk:** Low–Medium — trigger maintenance on schema change; tokenizer/locale choices. All record
  writes go through `records.zig`, so the FTS table can't drift.
- **Depends on / ordering:** Slots onto the existing compiler. Do early — high ratio.

#### B2. Aggregations & grouping — **Effort M, Risk Medium, Parity**
- **What:** `count`/`sum`/`avg`/`min`/`max` with `groupBy`, exposed via a stats endpoint or a
  `count=true` list flag.
- **Why:** Dashboards, "X items in cart," "posts per author." Today clients over-fetch and reduce client-side.
- **How it fits:** The compiler already produces a `WHERE`/joins/params triple; an aggregation mode
  emits `SELECT <aggs> ... GROUP BY <cols>` reusing the same join/filter machinery. Rules still apply
  (wrap as a guarded subquery). Cheap first step: an exact `totalItems`/`X-Total-Count` on list responses.
- **Risk:** Medium — must enforce access rules through the aggregate (no leaking counts of forbidden rows).
- **Depends on / ordering:** After the compiler is factored to share the join/where builder.

#### B3. Batch / transaction endpoint — **Effort M, Risk Medium, Differentiator**
- **What:** `POST /api/batch` accepting an ordered list of create/update/delete ops executed in one
  SQLite transaction; all-or-nothing.
- **Why:** Multi-record forms, offline-sync flush, "create order + line items atomically." A real
  differentiator: ZigBase's **single serialized writer** makes genuine ACID batches simple, where
  multi-node BaaSes only approximate them.
- **How it fits:** Acquire the writer once (`db.Pool` already serializes writes), `BEGIN`, loop
  dispatching into the existing `records.zig` create/update/delete with per-op rule checks,
  `COMMIT`/`ROLLBACK`. Each op can reference prior op results by id (for relation wiring). Record
  hooks and realtime `broadcast` fire per op at the same seams they already do.
- **Risk:** Medium — partial-failure semantics; response shaping; holding the writer for the batch
  duration (cap batch size; it's a global lock).
- **Depends on / ordering:** After rules + records are stable (they are). High value.

#### B4. `fields=` projection — **Effort S, Risk Low, Parity**
- **What:** `?fields=id,title,author.name` to trim returned columns (and expanded relations).
- **Why:** Smaller payloads, faster mobile clients. Standard REST expectation; explicitly deferred
  in `KNOWN_LIMITATIONS.md`.
- **How it fits:** The query layer already parses dotted field lists for `sort`/`expand`; reuse that
  parser to build the `SELECT` column list (validated against schema, never raw). Projection happens
  in the JSON serializer in `records.zig`.
- **Risk:** Low. Always return `id`; never let projection bypass rules or surface hidden fields.
- **Depends on / ordering:** Quick win; bundle with B5.

#### B5. ETags / optimistic concurrency — **Effort S–M, Risk Low, Parity**
- **What:** Return `ETag` on single-record GET; honor `If-Match`/`If-None-Match` on update/GET to
  prevent lost updates and enable client caching.
- **Why:** Two clients editing the same record currently silently clobber. ETags are the standard fix
  and save bandwidth via 304s.
- **How it fits:** Derive the ETag from the record's `updated` timestamp (+ id hash). On update, if
  `If-Match` doesn't match current `updated`, return `412 Precondition Failed`. All in `records.zig` +
  the response envelope.
- **Risk:** Low. Weak vs strong ETag choice; keep it simple.
- **Depends on / ordering:** Independent quick win.

#### B6. Soft-delete — **Effort M, Risk Low–Medium, Parity**
- **What:** Opt-in per collection: deletes set `deleted` instead of removing the row; list queries
  filter it out by default; restore + purge endpoints.
- **Why:** Trash/undo, audit, accidental-delete recovery — heavily requested in BaaS land.
- **How it fits:** A collection option adds a `deleted` autodate-ish column. The query compiler injects
  `AND deleted IS NULL` unless `?deleted=include`. Cascade-delete and file cleanup (the `Storage`
  vtable's `deleteRecord`) must respect soft mode.
- **Risk:** Low–Medium — unique constraints vs soft-deleted rows; relation integrity; centralize the
  filter in the compiler so nothing forgets it.
- **Depends on / ordering:** After the compiler injection point exists.

#### B7. JSON-field querying — **Effort M, Risk Medium, Parity**
- **What:** Filter/sort on paths inside `json` fields, e.g. `meta.country = "US"`.
- **Why:** The `json` field type exists but is opaque to the query language — you can store
  structured data but not query it.
- **How it fits:** Extend the lexer/parser to accept `field.path.into.json`, and the compiler emits
  SQLite `json_extract(col, '$.path')` (parameterizing the *value*, validating the column is a json
  field).
- **Risk:** Medium — path-injection safety (paths come from input → must be tokenized/validated, not
  string-built); index strategy for hot paths (pair with B8 expression indexes).
- **Depends on / ordering:** After B4/B5; benefits from B8.

#### B8. Indexes & constraints management — **Effort M, Risk Medium, Parity**
- **What:** First-class create/drop of indexes (unique + composite + expression) via the collection
  schema and admin UI.
- **Why:** `indexes` is already stored as JSON on `_collections` and per-field `unique` exists, but
  there's no rich management surface. Performance at scale needs this.
- **How it fits:** `ddl.zig` already emits index DDL and rebuild plans; add index diffing on
  collection update (create/drop to match the declared set). Surface in the admin schema editor.
  Expression indexes enable B7 (json) performance.
- **Risk:** Medium — index creation can be slow on big tables (do it in the writer/migration path, warn).
- **Depends on / ordering:** Foundational for B2/B7 performance.

#### B9. Computed / virtual fields — **Effort M, Risk Medium, Differentiator**
- **What:** Schema fields whose value is derived (a SQLite expression, or — differentiator — a
  comptime Zig function in embedded mode).
- **Why:** `fullName`, `priceWithTax`, denormalized counts without client logic.
- **How it fits:** SQLite generated columns for the pure-SQL case (DDL already in `ddl.zig`). In
  embedded/framework mode, a **record hook** (which already exists in `events.zig`) computes the
  value at serialize time — leans into the Zig angle.
- **Risk:** Medium — generated columns can't be indexed in all modes; rule/filter interaction.
- **Depends on / ordering:** After B8; overlaps with the existing hooks.

---

### C. Files & media

#### C1. S3 (and S3-compatible) storage plugin — **Effort M, Risk Low, Parity**
- **What:** An `S3StoragePlugin` (comptime plugin) wrapping an `S3Storage` that implements the
  existing `Storage` vtable; works with AWS S3, R2, MinIO, B2.
- **Why:** Local disk doesn't survive ephemeral/edge deploys or scale horizontally. Highest-value
  plugin; explicitly deferred in `KNOWN_LIMITATIONS.md`.
- **How it fits:** Implement `put`/`delete`/`deleteRecord` against the S3 REST API (SigV4 signing via
  `std.crypto`), and return `null` from `localPath` — which the design **already anticipates** (the
  sendFile path handles a null local path). Wrap it in the comptime-plugin contract
  (`create`/`interface`/`deinit`) so it drops in via `App(.{ .storage = S3StoragePlugin })` or a
  `ZIGBASE_STORAGE=s3` config switch on the default plugin. **Zero changes to `records.zig`/`files/`
  callers.**
- **Risk:** Low — SigV4 is the only fiddly part; well-specified.
- **Depends on / ordering:** Independent; high priority. Proves the plugin pattern generalizes.
  Enables C3/C4.

#### C2. Image thumbnails / transforms — **Effort L, Risk Medium, Parity**
- **What:** On-the-fly or on-upload resize/crop/format, requested via `?thumb=100x100` on file URLs.
- **Why:** The single most-requested PocketBase-parity file feature; avatars/galleries need it.
  Deferred in `KNOWN_LIMITATIONS.md`.
- **How it fits:** Adds an image-decode/encode dependency (vendor a small C lib like stb_image, or
  shell to libvips if present). Cache derived images via the `Storage` vtable (local or S3 via C1).
  A `thumb` query param on the file-serving handler (or the `onFileServe` hook) triggers
  generate-or-serve-cached.
- **Risk:** Medium–High — image codecs are a memory/CPU/security surface; cache invalidation; a new C
  dep cuts against the zero-dep ethos (gate it behind a build flag).
- **Depends on / ordering:** After C1. Larger effort.

#### C3. Signed URLs & direct-to-S3 upload — **Effort M, Risk Low–Medium, Parity+Diff**
- **What:** Pre-signed time-limited GET URLs (offload downloads to the CDN/bucket) and presigned PUT
  so big uploads bypass the app process entirely.
- **Why:** Removes ZigBase from the bandwidth path for large media; cheaper and faster.
- **How it fits:** Extends C1's SigV4 signing to produce presigned URLs. The short-lived
  **file-token** mechanism already exists (`ZIGBASE_FILE_TOKEN_TTL`) — generalize it: for local
  storage keep tokens; for S3 hand back a presigned URL.
- **Risk:** Low–Medium — presign correctness; enforce access rules *before* issuing the URL.
- **Depends on / ordering:** After C1.

#### C4. Resumable / chunked uploads — **Effort L, Risk Medium, Parity**
- **What:** tus-style resumable uploads for large/flaky-network files.
- **Why:** Mobile uploads of videos/large assets fail on flaky networks and restart from zero today.
  Deferred in `KNOWN_LIMITATIONS.md`.
- **How it fits:** New upload endpoints that accept ranges and assemble; finalize into the `Storage`
  vtable (`put`) or S3 multipart. Mostly orthogonal to the rest.
- **Risk:** Medium — partial-state cleanup/GC; protocol surface.
- **Depends on / ordering:** After C1/C3. Lower priority than thumbnails for most apps.

---

### D. Framework / DX (the Zig differentiators)

> The comptime framework already exists: `App(cfg)` wires record-lifecycle hooks, the
> `onAuth`/`onFile*`/`onBootstrap`/`onBeforeServe`/`onBeforeTerminate` lifecycle hooks, custom
> routes, a cron/interval/reactive scheduler, comptime storage/mailer plugins, and comptime pool
> levers. The ideas here *extend* that framework rather than introduce it.

#### D1. Comptime-typed collections → generated record structs — **Effort L, Risk Medium, Differentiator**
- **What:** Define collections in Zig at comptime; ZigBase codegens typed record structs and
  compile-time-validates that rules/indexes reference real fields.
- **Why:** No other BaaS can do this. Embedding apps get `Post{ .title: []const u8, .author: Id }`
  and a *compile error* when a rule references a renamed field — instead of `std.json.Value` and
  runtime surprises. The natural next step now that `App(cfg)` already comptime-validates hooks/routes.
- **How it fits:** Add a `.collections` group to the `cfg` struct (alongside the existing
  `.hooks`/`.routes`/`.cron`/`.storage`/`.mailer`/`.pools` keys, all already guarded). Generate
  structs from that comptime schema; `records.zig` (de)serialization specializes per type. The schema
  engine's `FieldType`→column-affinity mapping already exists to drive codegen.
- **Risk:** Medium — comptime metaprogramming complexity; dynamic (admin-created) collections must
  coexist with static ones.
- **Depends on / ordering:** Builds on the existing `App(cfg)` dispatch. Prerequisite for D2's
  type-safe SDK angle and A7's compile-time-checked roles.

#### D2. Generated client SDK (TS/JS) from schema — **Effort M, Risk Low, Parity+Diff**
- **What:** A `zigbase gen-sdk` command emitting a typed TypeScript client from the live schema
  (collections, fields, relations, auth).
- **Why:** Front-end DX; type-safe queries; the thing that makes adoption sticky. PocketBase's JS SDK
  is a big draw — but ours is *generated from your actual schema*, so it's always in sync.
- **How it fits:** A CLI subcommand (the CLI/`runCli` surface already exists) reads `_collections`
  and emits `.ts` types + a thin fetch wrapper over the REST/realtime API. Pure codegen, no runtime
  coupling. With D1, the source of truth is the comptime schema.
- **Risk:** Low. Keeping it in sync with API changes is the main maintenance cost.
- **Depends on / ordering:** Independent; high adoption value once the REST surface stabilizes.

#### D3. Testing helpers / harness — **Effort S–M, Risk Low, DX**
- **What:** A public test harness to boot ZigBase on an ephemeral port against a temp data dir, seed
  collections/records, and assert — for both core and embedding-app authors.
- **Why:** `App(cfg).run(init, cfg)` already boots without CLI parsing; promoting an ephemeral-boot
  helper to a supported API lets framework users TDD their hooks/routes/jobs.
- **How it fits:** Package the existing internal boot pattern (used by the test suite) as a reusable
  module; expose seeding helpers over the existing records API.
- **Risk:** Low.
- **Depends on / ordering:** Useful alongside any framework work; cheap.

#### D4. Admin API for logs / metrics / settings + rule hot-reload — **Effort M, Risk Medium, Parity**
- **What:** Authenticated admin endpoints for request/error logs, metrics, editable settings, and
  hot-reloading access rules without restart.
- **Why:** The admin SPA does collections/records/realtime/OAuth config, but **has no logs or
  settings screens** (per `KNOWN_LIMITATIONS.md`) and the editor is a plain textarea. Ops visibility
  is the gap.
- **How it fits:** Backs the admin SPA. Rules already compile per-request from `_collections`, so
  editing a rule *already* takes effect without restart — formalize/expose that. Logs/metrics depend
  on E1/E2. Settings (SMTP, rate limits, storage) live in a `_settings` table.
- **Risk:** Medium — exposing logs safely (no secret/token leakage).
- **Depends on / ordering:** After E1/E2.

#### D5. WASM plugins — **Effort L, Risk High, Differentiator (speculative)**
- **What:** Load sandboxed WASM modules as hooks/handlers for users who can't recompile the binary.
- **Why:** Bridges "recompile Zig" (the current `App(cfg)` model, max power) and "no extensibility
  without a toolchain." Sandboxed, language-agnostic.
- **How it fits:** A WASM runtime exposing a host API (record access, HTTP) to guest modules at the
  *same* hook seams the comptime dispatch already defines (`events.zig`).
- **Risk:** High — runtime size/security; cuts against single-static-binary simplicity.
- **Depends on / ordering:** Long-tail; only if demand proves recompilation is a real barrier.

---

### E. Ops & observability

#### E1. Structured logging — **Effort S, Risk Low, Parity**
- **What:** Structured (JSON) request/error logs with levels, request ids, latency; configurable sink.
- **Why:** Current logging is ad-hoc `std.log`. Production needs greppable, shippable logs. (Note: the
  mailer's `LogMailer` intentionally logs message bodies/tokens in dev — structured logging should be
  able to redact/level those out for prod.)
- **How it fits:** A thin logging module wrapping `std.log` with a JSON formatter; assign a request id
  in the `api` layer and thread it through. Complements the existing Sentry integration (`report/sentry.zig`).
- **Risk:** Low.
- **Depends on / ordering:** Early; feeds D4 and E2.

#### E2. Metrics (Prometheus) + health/readiness probes — **Effort S–M, Risk Low, Parity**
- **What:** `/metrics` (Prometheus text format) with request counts/latency/error rates, DB pool stats
  (the reader pool already tracks warm-connection state), realtime connection counts; plus `/readyz`
  distinct from the existing `/api/health`.
- **Why:** Standard for any production deploy; readiness (vs liveness) matters for rolling deploys.
- **How it fits:** Counters/histograms incremented in the `api`/`db`/`realtime` layers; a handler
  renders the text format. The reader pool and realtime hub already hold the stats worth exposing.
- **Risk:** Low.
- **Depends on / ordering:** After E1.

#### E3. Backups / restore (online SQLite) — **Effort M, Risk Medium, Parity**
- **What:** Scheduled, consistent online backups (SQLite Online Backup API or `VACUUM INTO`) to local
  or S3; a restore command; include the file-storage tree.
- **Why:** Single-file SQLite makes backups *easy and reliable* — a genuine ergonomic win to surface
  as a first-class, scheduled, admin-visible feature.
- **How it fits:** A `zigbase backup`/`restore` CLI + a **scheduled cron job** (the scheduler already
  runs cron/interval jobs with backoff-retry — no new timer needed). Ship backups through the
  `Storage` vtable / S3 (C1). Snapshot DB + files consistently.
- **Risk:** Medium — consistency between DB and file tree during backup; restore safety.
- **Depends on / ordering:** Backup-to-S3 wants C1; scheduling is *already available*.

#### E4. Migrations tooling / schema versioning for dynamic collections — **Effort M, Risk Medium, Parity**
- **What:** Generate migrations from schema diffs, dry-run, and an `up`/`status` CLI for *user-created*
  collections — beyond the current system-schema `_migrations` ledger.
- **Why:** `migrations.zig` versions *system* schema and `ddl.zig` can rebuild a table, but
  admin-created collections live only in the DB. Teams need to version/replay schema across
  environments (dev→prod).
- **How it fits:** Export `_collections` as declarative migration files; apply/diff on boot reusing
  `ddl.zig`'s `rebuildPlan`. Dovetails with D1 (comptime-defined collections are inherently
  version-controlled).
- **Risk:** Medium — diff correctness; destructive-change guards.
- **Depends on / ordering:** Standalone; more valuable once collections are heavily used.

#### E5. Config file + secrets + selective reload — **Effort S–M, Risk Low, Parity**
- **What:** A config *file* (TOML/JSON) layered under env/flags, plus SIGHUP/endpoint reload of
  safe-to-change settings; secrets from files/env not flags.
- **Why:** `config.zig` is flat env+flags. The surface is already growing (SMTP host/port/user/pass/
  from, file-token TTL, realtime origins, Sentry DSN) and will grow more (rate limits, S3) — structured
  config + partial reload becomes worthwhile.
- **How it fits:** Extend `Config.load` to merge a file layer beneath env/flags (precedence already
  modeled). Mark reloadable vs boot-only fields.
- **Risk:** Low.
- **Depends on / ordering:** Do alongside C1 / A1 as their config surface grows.

#### E6. Multi-tenancy & quotas — **Effort L, Risk High, Parity+Diff**
- **What:** Isolated tenants (separate SQLite file per tenant, or a tenant-scoping column) with
  per-tenant quotas (storage, rows, rate).
- **Why:** SaaS builders want to host many customers on one ZigBase. **DB-per-tenant is a natural fit
  for single-file SQLite** and a real differentiator (cheap, hard-isolated tenants).
- **How it fits:** Either route requests to a per-tenant `db.Pool` (strong isolation, leans into
  SQLite's file model — and the reader pool generalizes per-DB) or add a tenant column threaded
  through the compiler/rules. Quotas hook into A1's counter infrastructure.
- **Risk:** High — pervasive change; pool management for many DBs; cross-cutting.
- **Depends on / ordering:** Late; after A1/A7 and the compiler is factored.

---

### F. Realtime & eventing

#### F1. Outbound webhooks — **Effort M, Risk Medium, Parity**
- **What:** Configurable HTTP callbacks on record events (create/update/delete) with retries, HMAC
  signing, and a delivery log.
- **Why:** Integrations (Slack, Zapier, your own services) need server-side push, not just WS subscriptions.
- **How it fits:** Tap the **same mutation seam** the realtime `ws.broadcast` already fires from (and
  the after-create/update/delete hooks) to enqueue webhook deliveries into an outbox table; a
  **scheduled job** (already supported) drains it with exponential-backoff retries (the scheduler
  already does backoff) and signs payloads via `std.crypto` HMAC.
- **Risk:** Medium — retry/backoff/idempotency; SSRF guardrails on user-supplied URLs.
- **Depends on / ordering:** Needs a durable queue (F4) + the scheduler (have it). Pairs with F4.

#### F2. Presence & broadcast/RPC channels — **Effort M, Risk Medium, Differentiator**
- **What:** Presence ("who's online in this doc"), ephemeral broadcast channels, and client→server RPC
  over the existing WS connection.
- **Why:** Collaborative apps (cursors, typing indicators, live dashboards) need presence/broadcast
  beyond record-change subscriptions.
- **How it fits:** Extend `realtime/{hub,protocol}.zig` with non-record topic types (presence rosters,
  broadcast). The hub already tracks connections + subscriptions — presence is a roster view over that.
- **Risk:** Medium — fan-out cost at scale on a single node; protocol additions.
- **Depends on / ordering:** Builds directly on existing realtime; medium priority.

#### F3. Change-data-capture / event log — **Effort M, Risk Medium, Differentiator**
- **What:** An append-only, queryable log of all record changes (who/what/when/old→new), with a
  replay/cursor API.
- **Why:** Audit trails, offline-sync deltas ("everything since cursor X"), debugging. Underpins
  reliable webhooks (F1) and sync.
- **How it fits:** Write change events to an `_events` table at the same mutation seam
  `ws.broadcast`/after-hooks already use; expose a cursor-paginated read endpoint. Single writer makes
  ordering trivial (monotonic rowid = cursor).
- **Risk:** Medium — log growth/retention; PII in old→new diffs.
- **Depends on / ordering:** Enables F1 retries and offline sync; do before/with F1.

#### F4. Durable job/outbox queue + retries — **Effort M, Risk Medium, Foundational**
- **What:** A SQLite-backed durable queue with at-least-once delivery, retries, and a worker — used by
  webhooks (F1), scheduled backups (E3), and any async side effect.
- **Why:** Several features need "do this reliably, later, with retries." Build the *durable* layer
  once; the scheduler gives you the worker.
- **How it fits:** An `_jobs` table drained by a **scheduler interval job** (already exists, with
  backoff-retry). SQLite + single writer gives simple, correct queue semantics without external infra —
  on-brand for single-binary. Note the current `app.submit` is a *detached, non-durable* thread (per
  `KNOWN_LIMITATIONS.md`); F4 is its durable counterpart.
- **Risk:** Medium — visibility timeout/locking; poison-job handling.
- **Depends on / ordering:** Foundational for F1, reliable webhooks, E3. Reuses the scheduler.

---

### G. Scaling (respecting one-writer SQLite)

#### G1. Read replicas / LiteFS-style distribution — **Effort L, Risk High, Differentiator**
- **What:** Read-replica fan-out (LiteFS/litestream-style streaming replication) so reads scale
  horizontally and the DB survives node loss.
- **Why:** Clustering is an explicit non-goal today; the natural first relaxation is read-scaling +
  durability without abandoning SQLite.
- **How it fits:** Integrate with LiteFS (FUSE) externally, or implement WAL streaming. Writes still go
  to the single primary (matches the existing serialized-writer model exactly); replicas back the
  reader pool (which already exists).
- **Risk:** High — replication lag semantics; consistency expectations; ops complexity.
- **Depends on / ordering:** Late; only when single-node read capacity is a *proven* ceiling.

#### G2. Connection-pool tuning & backpressure — **Effort S–M, Risk Low, Parity**
- **What:** Runtime-configurable reader-pool size, busy-timeout/retry tuning, write-queue depth limits +
  backpressure, and pool metrics.
- **Why:** Squeeze maximum throughput out of the single node before reaching for G1. The reader pool
  exists with a comptime `.pools.readers` cap — the next step is *runtime* config + backpressure.
- **How it fits:** Expose the pool params via config (E5) in addition to the comptime lever; add metrics
  (E2); apply backpressure when the write queue is saturated rather than buffering unbounded.
- **Risk:** Low.
- **Depends on / ordering:** Cheap, do before G1. Pairs with E2 metrics.

#### G3. Litestream-style continuous backup to S3 — **Effort M, Risk Low–Medium, Parity**
- **What:** Continuous WAL shipping to object storage for point-in-time recovery.
- **Why:** Durability for single-node deploys without full replication; complements E3 snapshots.
- **How it fits:** Either integrate litestream (external) or ship WAL frames via C1's S3 backend.
- **Risk:** Low–Medium.
- **Depends on / ordering:** After C1; complements E3.

---

## Suggested sequencing (next 2–3 increments)

**Increment 1 — "Production-grade & safe" (finish the last gaps that block a real public deploy).**
- A1 Rate limiting (S) — stop credential stuffing + email-bombing before exposing anything; now
  urgent because the mailer *actually sends*.
- A2 SMTP TLS/STARTTLS (S–M) — the mailer exists and is wired; TLS is what lets it reach real
  providers instead of just dev sinks.
- B4 `fields=` + B5 ETags (S) — cheap, broadly-useful API hardening (both deferred items).
- E1 Structured logging (S) — greppable prod logs; redact mailer/dev token logging in prod.
- *Rationale:* The mailer/framework/plugins are done; this increment closes the *remaining*
  operational gaps that keep a deploy from being safe and complete. Small and mostly independent.

**Increment 2 — "Serious BaaS table-stakes" (parity + disproportionate wins).**
- B1 FTS5 search (M) — nearly-free given FTS5 is compiled in; high perceived value.
- C1 S3 storage *plugin* (M) — uses the existing vtable + comptime-plugin contract; enables edge deploys.
- B3 Batch/transaction endpoint (M) — differentiator the single-writer model makes easy.
- A5 API keys + A3 TOTP (M) — round out auth to "trustworthy for real accounts."
- E2 Metrics + G2 pool tuning (S–M) — operability + throughput headroom on the existing reader pool.
- *Rationale:* Each rides an abstraction already in place (compiler, `Storage`/`Mailer` vtable +
  plugin pattern, single writer, `RequestContext`, scheduler). High value, medium effort, low risk.

**Increment 3 — "Differentiate on Zig + grow the framework."**
- D1 Comptime-typed collections → generated record structs (L) — the framework keystone, built on
  the `App(cfg)` dispatch that already exists.
- F4 Durable job queue + F3 CDC/event log + F1 webhooks (M each) — eventing, built on the *existing*
  scheduler and the `ws.broadcast`/after-hook mutation seam.
- D2 Generated TS SDK (M) + D3 test harness (S–M) — the adoption-driving DX story.
- C2 Image transforms (L) + C3 signed URLs — finish the media story on top of S3.
- *Rationale:* Operational and parity foundations are solid by now; spend effort where ZigBase is
  *uniquely* good (comptime, single-binary, embeddable). F4 lands early in the increment because
  reliable webhooks and scheduled backups both want a durable queue.

**Deferred / opportunistic:** A6 (`.table` session mode as the default — awaits perf data), A7 RBAC
(deferred by choice — see recipe), A8 (named OAuth presets beyond the current table — pick off as
requested), B2/B6/B7/B8/B9 (data depth, as usage demands), D4 admin logs/settings UI, E3/E4/E5/E6 (ops maturity),
F2 (presence), G1/G3 (multi-node — only when single-node limits are *measured*), D5 (WASM — only if
recompilation proves a barrier).

---

### Appendix: parity vs differentiator at a glance

- **Already shipped on current `main` (do NOT re-propose as missing):** the embeddable comptime
  framework `App(cfg)` (record + lifecycle hooks, custom routes, cron/interval/reactive scheduler,
  `app.submit`); a pluggable `Mailer` vtable with `LogMailer` + `SmtpMailer` wired into auth;
  comptime storage/mailer plugins; comptime pool levers (`.pools.readers`/`.pools.jobs`); a
  reader-connection pool; the `Storage` vtable (S3-ready); FTS5 compiled in; schema migrations +
  `ddl.zig` rebuild plans; OAuth2 PKCE; rule-filtered realtime; Sentry error reporting; rate
  limiting; SMTP TLS; per-device session management (opt-in `.table` mode) + REST/SDK surface;
  generic OIDC discovery.
- **PocketBase-parity gaps still to close:** S3 *implementation*, image transforms, MFA, API keys,
  named OAuth presets beyond the current table, FTS *wiring*, aggregations, soft-delete, `fields=`,
  ETags, webhooks, metrics/logs UI, backups, dynamic-collection migrations, generated SDK.
- **Differentiators (the Zig/comptime/single-binary/embeddable angle):** comptime-typed record
  structs (D1), compile-time-validated schema+rules+roles (A7+D1), atomic batch endpoint on the
  single serialized writer (B3), DB-per-tenant via single-file SQLite (E6), trivially-reliable
  SQLite backups (E3), CDC/event log with monotonic cursors (F3), embedding the whole BaaS as a
  library in a larger Zig program (already real via `App(cfg).runCli`), and single-binary edge deploy.
