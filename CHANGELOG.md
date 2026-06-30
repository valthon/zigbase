# Changelog

All notable changes to ZigBase are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.9.0] - 2026-06-30

### Breaking

- Explicit consumer migrations (`.migrations`) now receive a `*zigbase.Migrator` instead of `(alloc, io, w)`. Change each migration's `up` from `fn (alloc: std.mem.Allocator, io: std.Io, w: *zigbase.Db) anyerror!void` to `fn (m: *zigbase.Migrator) anyerror!void`; the writer is `m.db`, the arena is `m.arena`, and `m.io` is the request `std.Io`. `Migrator` carries the active SQL **dialect** so the same migration can run on SQLite or Postgres: `m.execLowered(sql)` runs SQLite-flavor DDL/seeds lowered to the active backend (SQLite byte-identical), `m.exec(sql)` runs raw backend-specific SQL (fails loud on the wrong backend), and `m.dialect.kind` / `m.rawFor(.postgres, …)` / `m.requireBackend(.sqlite)` branch per backend. SQLite-only consumers that never build with `-Dpostgres` keep working by switching `w` → `m.db` (or `m.exec`).

### Features

- Relationship-based row abilities (#155). Declare per-collection, per-action authorization by the principal's relationship to the row with `App(.{ .abilities = .{ .projects = .{ .update = .{ .relationship = .{ .via = "account", .min_role = .editor } } } } })`: a row is authorized when the principal holds a membership (role ≥ `.min_role`) of the account named by the `.via` relation field. Each rule lowers to a bound `"<col>"."<via>" IN (?,?,…)` predicate over the principal's qualifying membership account-ids — the same shape the `in` operator and `@request.account.ids` macro emit.
- Abilities compose into the existing guard stack as `WHERE (filter) AND (rule) AND (ability) AND (tenant_field = ?) AND (ttl)`, and force a per-row check even when the access rule alone would allow (so `@public` + an ability still authorizes each row). Fail-closed throughout: no qualifying membership yields a constant-false predicate, account-ids are always bound parameters, a locked rule still denies first, and superusers bypass abilities. Comptime-validated — an ability naming an unknown collection, a `.via` that is not a relation field, or a `.min_role` not in `.tenancy.roles` is a compile error.
- The LIST endpoint (`GET …/records`) narrows to the rows the principal may view by relationship too: the view-ability predicate is AND-ed into the bulk read path, and a `.rules.list = "@public"` collection with a view ability now returns the ability-narrowed set (HTTP 200) instead of erroring.
- `ctx.can(.action, "collection", id)` authorizes a specific record from a custom route through the same composed policy (rule + ability + tenant scope) the REST chokepoints use. New introspection endpoint `GET /api/collections/:col/records/:id/abilities` returns a JSON object of booleans like `{"view": true, "update": false, "delete": false}` — the actions the current principal may perform on that record (the endpoint itself requires view access, so it never leaks a record's existence).
- Back-compat: a collection with no `.abilities` entry composes a null predicate, so its authorization decisions and compiled SQL are byte-identical to the pre-abilities engine (pinned in `policy.zig`).
- Built-in product analytics (#158): event capture + declarative rollups. Emit an event from any hook/route/job with `ctx.track("user.signup", .{ .plan = "pro" })` — it appends one immutable row to the new `_events` system collection (migration `0015_events`) with the actor (the authenticated principal), the account (the request's active tenant scope), and the timestamp all stamped SERVER-SIDE (a client cannot forge them); `payload` is stored as opaque JSON.
- Declarative rollups: `App(.{ .analytics = .{ .rollups = .{ .signups_daily = .{ .event = "user.signup", .every = .{ .interval = .hourly }, .group_by = .{ .account = true, .time_bucket = .day }, .metric = .count } } } })` registers one scheduled job (on the existing cron/interval scheduler) per rollup that incrementally aggregates `_events` into a `_rollup_<name>` summary table. Aggregation is idempotent (a persisted watermark means a run only counts new events) and identifiers are gated through `schema.isValidIdentifier`. The config is comptime-validated — an unknown `.group_by`/`.metric`, a missing/empty `.event`, or a non-identifier rollup name is a compile error.
- Tenant-scoped read API: `GET /api/analytics/events?name=&actor=&since=&limit=` (the raw activity feed) and `GET /api/analytics/rollups/:name?from=&to=` (a rollup's summary rows). Both are authenticated and FAIL CLOSED — a superuser sees everything, a member sees only their active account's data (or, with tenancy disabled, only their own events for the feed), and a non-superuser can never read another account's events or rollups.
- Back-compat: with no `.analytics` config the `_events` table is still seeded (harmless) but no rollup job is scheduled; `ctx.track` is usable standalone.
- Email subsystem (#154): a transactional-mail core on top of `ctx.mail()`. A minimal, safe
  template engine (`mail/template.zig`) renders multipart HTML + plain-text from a typed data
  context — `{{ var }}` is HTML-escaped by default, raw output is an explicit `{{{ var }}}` opt-in,
  with named partials (`{{> name }}`) and a shared layout. No arbitrary code evaluation.
- First-class HTTP-API mail providers behind the existing `Mailer` vtable: **Amazon SES**
  (`SesMailer`, SESv2 `SendEmail` with AWS SigV4 signing) and **Postmark** (`PostmarkMailer`).
  Select them via `App(.{ .mailer = … })`, swapping providers without touching call sites. SMTP /
  Command backends are unchanged.
- A per-message `From` override (`mail.Email.from` / `MailMessage.from`, additive `null` default)
  honored by every backend, so a tenant can send as its own verified address rather than the app's
  global From.
- `CaptureMailer` — an in-memory `Mailer` backend for tests: assert outbound mail (subject,
  recipient, both body parts) with no SMTP server and no network. Plus a dev `renderPreview` that
  produces a self-describing HTML preview of one message.
- Verified per-account **sender identities** (`_sender_identities`, migration `0016_email`): request
  verification of a From address (`POST /api/senders`, which emails a single-use token), confirm it
  (`POST /api/senders/:id/verify`), and list (`GET /api/senders`). All routes are tenant-scoped and
  fail closed — a member can only manage its own account's senders.
- Bounce/complaint **suppression** (`_suppressions`, same migration) with an inbound webhook
  (`POST /api/mail/webhooks/:provider`, SES + Postmark payload shapes) that upserts a suppression on
  a hard bounce or complaint.
- `ctx.mail().deliverLater(msg, .{ .queue = "…" })` reads as the async transactional-send entry
  point (an alias of `enqueue`). `ctx.mail()` now attributes mail to the request's active account
  scope automatically, which is the engagement point for the new enforcement.
- New `.mail` framework config key: `App(.{ .mail = .{ .require_verified_sender = true,
  .check_suppression = true, .webhook_secret = "…" } })`. All toggles default OFF — an app that only
  calls the existing mailer is completely unaffected.
- Deferred to 0.9.x fast-follows (not in this release): bulk/throttled personalized list sends;
  scheduled/sequenced (drip) sends; CSS-inlining + inline-image hosting; one-click unsubscribe /
  list management. The send job + suppression + verified-sender checks are the seams those build on.
- The admin UI now shows a read-only **database-backend badge** ("SQLite" / "Postgres") in the sidebar, so you can tell at a glance which backend an instance is running on. It is sourced from a new field on the existing health endpoint: `GET /api/health` now returns `{"status":"ok","backend":"sqlite"|"postgres"}`. The badge is the backend *kind* only — the connection string, host, and credentials are never exposed.
- Typed-client codegen (`gen-client` / typegen) can now point its data-dir adapter at a **`postgres://` data source** (in a `-Dpostgres` build), not just a local `data.db` directory: `acquire(--data-dir <postgres://…>)` opens a Postgres handle through the tagged-union `db.Db` and reads ZigBase's own `_collections` metadata. Because the schema metadata is backend-neutral, the generated TypeScript client is byte-identical whether the instance is SQLite- or Postgres-backed, so the ts-sdk snapshot is unaffected by backend.
- Added a **`migrate-db` CLI subcommand** that copies an existing SQLite-backed instance into a fresh PostgreSQL database — schema **and** data (#159, PR-9): `zigbase migrate-db --from ./zb_data/data.db --to "postgres://…"`. Highlights:
  - **Provisions the equivalent schema** on the target via the same code paths the server uses: runs the system migrations, then creates every collection's record table (including runtime-created collections, with their indexes and relation foreign keys) from the source's `_collections` metadata.
  - **Bulk-loads every system + record table atomically** — the whole load runs in one transaction, so a mid-migration failure rolls the target back to a clean state (schema present, zero migrated rows) rather than leaving it half-populated.
  - **Preserves record ids, timestamps, and `_collections` metadata** (collection ids survive verbatim) and **carries encrypted-field envelopes byte-for-byte** — ciphertext is never decrypted/re-encrypted, so no `ZIGBASE_FIELD_KEY` is passed to the tool and the same key reads the data on Postgres afterward.
  - **Resets the analytics rollup watermarks** so rollups recompute against the target's regenerated `_seq` (a verbatim-copied watermark would otherwise silently stop counting events post-migration).
  - **Verifies integrity**: refuses a non-empty target unless `--force`, reports per-table row counts measured on the **target**, and fails loud on any source/target count mismatch.
  - Present in every binary, but the PostgreSQL side requires a `-Dpostgres` build — a stock binary fails with a clear error rather than silently no-op'ing.
  - Does **not** copy the target's freshly-applied `_migrations` ledger or the SQLite-only FTS5 shadow tables; the collection's `.searchable` metadata is preserved so the Postgres full-text index reprovisions on the next `zigbase serve`. See the "Migrating an existing SQLite instance to Postgres" guide in `docs/framework.md`.
- Filter/rule grammar: new `in` set-membership operator — `field in ("a", "b")` (literal list) or `field in <list-macro>`, compiled to a parameter-bound `IN (?, …)`. An empty set matches nothing (fail-closed).
- Filter/rule grammar: new `@request.account.id`, `@request.account.role`, and the list-valued `@request.account.ids` macros — the foundation for multi-tenancy and row-level/relationship authorization. They resolve to `""`/empty until the tenancy resolver ships, so existing rules are unaffected.
- First-class search on the list endpoint (#157). Full-text search ships in the **default build**: mark any `text`/`editor` field `.searchable = true` and ZigBase provisions an FTS5 **external-content** index per collection at startup (`"<col>_fts"`, `content='<col>'`) plus `INSERT`/`UPDATE`/`DELETE` triggers that keep it in lock-step with the base table — no doubled storage and no migration. Query it with `?search=<terms>` (alias `?q=`); results are ranked by `bm25` relevance and support the basic FTS5 operators (`AND`/`OR`/`NOT`, trailing `*` prefix).
- Search composes WITH the existing authorization stack AND with structured filters — it is **not** a separate, unscoped query. The FTS `MATCH` predicate is AND-ed into the *same* `records.list` composition as `filter` + list rule + ability + tenant-scope + ttl, so `?search=X&filter=Y` returns the intersection and a search on a tenant-owned or ability-guarded collection returns **only** the rows the caller may already view. Search terms are always **bound parameters** (never interpolated) and are lowered to a guaranteed-valid FTS5 query, so malformed input can never become a SQL error or injection; a search whose terms reduce to nothing (e.g. operator-only) matches no rows rather than returning the whole collection. A `search` on a collection with no `searchable` field returns 400. The `_fts` collection-name suffix is reserved (it backs the shadow tables).
- Opt-in vector / nearest-neighbor search behind a non-default `-Dvector` build flag. When enabled, ZigBase vendors and statically links [`sqlite-vec`](https://github.com/asg017/sqlite-vec), registers it on every connection, and adds a `?vector=<field>[:cosine|:l2]:<json-embedding>` KNN ordering that composes into the same scoped query; the embedding is validated (a non-empty JSON array of finite numbers) and bound, and a malformed or dimension-mismatched embedding returns a clean 400. In the default build sqlite-vec is **not** compiled or linked — the binary is byte-for-byte unaffected — and a `vector` query returns a clean 400 ("Vector search is not enabled in this build.").
- Account-scoped multi-tenancy (#156). Enable it with `App(.{ .tenancy = .{ .enabled = true, .auth_collection = "users" } })` and mark a collection's owning-account column with `.tenant_field = "account"`. Every read/write of a tenant-owned collection — and realtime delivery over WebSocket — is then auto-scoped to the request's active account via a bound `tenant_field = ?` predicate composed into the access-rule/TTL guard stack; create stamps the owning account (no client spoofing) and update rejects cross-tenant moves (a cross-tenant target is refused before the `before_update` hook runs).
- Realtime is tenant-scoped: a WebSocket connection resolves its active account at the handshake (signed `zb_account` cookie / `X-Account-Id` header) and verifies a membership; tenant-owned create/update/delete frames (incl. the delete snapshot) are filtered to the subscriber's account, and a connection with no resolved account receives nothing from a tenant-owned collection — even a `@public` one — so realtime can never leak across accounts.
- Tenant resolution: the active account is read from the `X-Account-Id` header (`.resolver = .header`) or a signed `zb_account` cookie and verified against an **active** `_memberships` row (one indexed SELECT, cached per request, fail-closed). `POST /api/accounts/:id/activate` verifies membership and sets the signed cookie for browser apps. The `@request.account.id` / `.role` / `.ids` rule macros are now populated from the resolved scope.
- New built-in system collections (migration `0014_tenancy`): `_accounts`, `_memberships`, `_invitations` (tables + indexes; membership lifecycle lands in a later PR). New collection option `.tenant_field` and config block `.tenancy = .{ .enabled, .resolver, .auth_collection, .roles }`, all comptime-validated (unknown key/resolver, empty roles, or a `tenant_field` naming a non-existent field is a compile error). Configurable tenant role total-order (`viewer < editor < admin < owner` by default). Tenant-owned collections are auto-indexed on the tenant column and logged at startup.
- Back-compat: an app with no `.tenancy` (or any collection without a `.tenant_field`) produces byte-identical SQL and authorization decisions to the pre-tenancy engine; superusers bypass tenancy and `zigbase.crossTenant(rctx)` is the explicit cross-account override for admin tooling.
- **`ctx.verifyCaptcha(provider, token) !CaptchaResult`** (#140) — verify CAPTCHA tokens from reCAPTCHA v2/v3, hCaptcha, and Cloudflare Turnstile via `ctx.http()`. Configure with `App(.{ .captcha = .{ .provider = .recaptcha_v3, .secret = "..." } })`; dev-bypass (returns `ok=true` without a network call) when secret is empty.
- Custom route handlers gain ergonomic `Ctx` helpers for shaping responses and reading the
  request:
  - Deferred response mutation — `ctx.setCookie(cookie)` / `ctx.addHeader(header)` queue
    cookies/headers that are merged onto whatever `http.Response` the handler returns, on
    **both** the success and error paths (a deferred Set-Cookie survives a handler error).
    The raw `http.Response` literal stays fully usable; handler-set cookies/headers are kept
    and the deferred ones appended.
  - Response builders — `ctx.json(status, value)`, `ctx.jsonError(status, code)` (emits
    `{"error":"<code>"}`), `ctx.html(status, body)`, `ctx.redirect(status, location)`, and
    `ctx.notFound()`, all allocating on the request arena.
  - Request reads — `ctx.query()` lazily parses + caches the decoded URL query string
    (`q.get("k") -> ?[]const u8`; `+` → space, `%XX` decoded) and `ctx.randomToken(n)` /
    `ctx.randomHex(n)` mint arena-owned random tokens.
  - `ctx.subjectCookie(name, opts)` — read-or-mint an opaque, anonymous-friendly per-visitor
    id stored in a cookie. Returns an existing well-formed value verbatim, otherwise mints
    one and queues a single Set-Cookie; idempotent within a request. An explicit `?subject=`
    query param still takes precedence.
- `http.Cookie` now carries an optional `domain` attribute (defaults to host-scoped).
- `ctx.mail()` — send outbound application mail from any route, hook, or job.
  `ctx.mail().send(.{ .to = …, .subject = …, .text = …, .html = …, .reply_to = … })`
  delivers synchronously through the configured mailer, and
  `ctx.mail().enqueue(msg, .{ .queue = "…" })` hands it to the background queue (the
  built-in `"mail"` job kind) for durable/memory delivery. A message carries an optional
  HTML alternative and `reply_to`; when both `text` and `html` are set the message is
  built as `multipart/alternative`.
- `mail.Email` gains optional `html_body` and `reply_to` fields (additive, `null`
  defaults — existing `Mailer` implementations and `Email` literals compile unchanged).
  `buildMessage` now emits a `text/html` part or a `multipart/alternative` body when an
  HTML alternative is present, so HTML mail works across every backend (SMTP / Command /
  custom plugins).
- Consumer mail is assertable in tests exactly like the framework's own auth mail: both
  `send` and the enqueued `"mail"` job route through the one `Mailer.send` vtable seam that
  feeds the dev-only `testcapture.mail` outbox.
- Background jobs & queues: a generic multi-queue / worker / job engine. Declare named
  `.queues` (backend `memory` (default) or `durable`, a `high`/`normal`/`low` `priority`, and a
  per-queue retry policy), named `.workers` (each bound to a subset of queues, drained in strict
  priority order, with a `concurrency` knob), and a `.jobs` kind→handler registry. A `.default`
  queue is always synthesized, and with no `.workers` declared a single implicit worker drains all
  queues. Enqueue from anywhere (routes, hooks, jobs) with the compile-checked
  `App.enqueue(ctx, .queue, .kind, payload)` or the runtime-validated `ctx.enqueue(.queue, .kind, payload)`;
  the payload is JSON-serialized and the kind handler receives that JSON.
- Durable queues persist to a new `_queue_jobs` table and are drained by a per-worker poller with
  at-least-once delivery: jobs are claimed under the writer, dispatched, then marked done / retried
  with backoff / failed (firing `.onError`) once attempts are exhausted. A reclaim sweep resets jobs
  stranded by a crashed worker, and a GC sweep reaps old done/failed rows — both installed only when
  a durable queue is declared (memory-only and no-queue apps install nothing).
- Memory queues run in-process on a detached thread with backoff retry (at-most-once across restart),
  so a queue works with zero schema by default.
- Consumer-facing realtime broadcast API for custom (non-record) channels, reachable from a
  custom route handler or a background job via `ctx.realtime()`:
  - `ctx.realtime().signal(topic)` — publish a signal-only `{"type":"signal","topic":"<topic>"}`
    frame so subscribers re-fetch over an authenticated GET (the recommended default for
    private/per-subject state — it carries no payload).
  - `ctx.realtime().broadcast(topic, payload)` — publish a payload-carrying
    `{"type":"message","topic":"<topic>","data":<payload>}` frame, delivered verbatim to every
    subscriber of `topic` (`payload` is any JSON-serializable value).
  - Clients use the **same** subscribe/unsubscribe WebSocket protocol they already use for record
    topics. A custom topic is any name that is not a collection; subscribing to a collection name
    still goes through that collection's normal record-channel authorization.
  - Both publish entry points are a no-op when the realtime reactor isn't running (tests/CLI), so
    they are safe to call unconditionally.
- New optional `App(.{ .realtime = .{ .canSubscribe = fn } })` config: a
  `fn(ctx: *Ctx, topic: []const u8) bool` predicate that gates who may subscribe to a custom
  topic. An unknown `.realtime` sub-key is a compile error.
- Custom routes gain a declarative guard pipeline that runs before the handler. `.auth` now accepts either an `AuthLevel` (`.public`/`.authed`/`.superuser`) **or** a guard struct — `.auth = .{ .path_secret = .{ .param = "token", .source = .{ .kv = "deploy_secret" }, .in = .path, .on_mismatch = .not_found } }` gates a route on a shared secret presented in the path (`.in = .path|.query|.header`) and resolved from `.kv`/`.settings`/`.config`. A new `.rate_limit = .{ .custom = .{ .max = N, .window_s = S } }` (plus optional `.rate_limit_key = fn(*Ctx) ?[]const u8`) adds a per-route rate-limit bucket; both compose on one route.
- `ctx.verifyPathSecret(param, stored)` — a constant-time escape hatch for handlers that gate themselves on a secret resolved by hand.
- `ctx.webhook(url, payload, .{…})` delivers outbound webhooks in the background on the built-in `"webhook"` job kind (riding the multi-queue engine). Transport errors, `5xx`, and `429` (honoring an integer `Retry-After`) are retried with backoff up to `retries` attempts; any other `4xx` is terminal. A terminal rejection or exhausted attempts fires `onError` with the new `.webhook` error phase. Options: `queue`, `retries`, `backoff`, `timeout_s`, `sign`, `idempotency`.
- `ErrorPhase` gained a `.webhook` variant. This is additive, but consumers whose `onError` handler `switch`es exhaustively over `ErrorPhase` must add a `.webhook` arm to keep compiling.

### Fixes

- **`.nocase` indexes are now genuinely case-insensitive on BOTH backends — closes the Postgres `.nocase` case-sensitivity caveat and fixes a SQLite lookup/uniqueness inconsistency (#159).** A comptime index marked `.collation = .nocase` (the documented email-uniqueness pattern the example apps use) used to provision **case-SENSITIVELY** on Postgres, because Postgres has no `COLLATE NOCASE` — so a `.nocase` UNIQUE index silently let `Bob@x.com` and `bob@x.com` both insert as separate identities. It now provisions a `lower("col")` **functional index** on Postgres (built-in; no `citext`/extension dependency), so a `.nocase` UNIQUE index rejects case-variant duplicates exactly as on SQLite. Lookups and comparisons now go through the matching case-insensitive form on each backend so they use that index and agree with its uniqueness: the auth identity/email lookups (`findByIdentity`/`findByEmail`) and filter/rule equality (`=`/`!=`/`in`) against a `.nocase` column emit `lower("col") = lower($n)` on Postgres and `"col" COLLATE NOCASE = ?n COLLATE NOCASE` on SQLite. This also makes SQLite `.nocase` *lookups* case-insensitive — previously a user registered as `Bob@x.com` could not log in as `bob@x.com` on SQLite even though the `.nocase` UNIQUE index treated them as the same identity; now both backends behave identically. The built-in auth identity uniqueness index remains case-sensitive (case-insensitive identity is opt-in via a `.nocase` index). The previous startup warning for `.nocase` indexes under Postgres is removed.

### Security

- Send-time enforcement is fail closed, and the engagement point is explicit (so existing simple
  SMTP apps never suddenly start rejecting): verified-sender enforcement engages only with
  `.mail.require_verified_sender = true` AND an account-scoped send — a tenant send whose From is not
  a verified `_sender_identities` row for the account is REJECTED; a system/superuser send (no
  account) bypasses. Suppression blocking engages only with `.mail.check_suppression = true` — a send
  to a hard-bounced/complained recipient is BLOCKED.
- The inbound bounce/complaint webhook verifies a shared-secret HMAC-SHA256 signature with a
  CONSTANT-TIME compare; the signed string binds the timestamp, provider, AND the target account
  (`X-Account-Id`) plus the body, so a captured event cannot be redirected to another tenant. A
  ±5-minute timestamp-freshness window rejects replays, and a wrong/missing/stale request is rejected
  (401). With no `webhook_secret` configured the route is disabled (404) — ingestion is strictly
  opt-in. NOTE: a genuine provider webhook cannot sign/scope itself, so it is GLOBAL-only;
  per-account scoping requires an operator-run signing relay (documented).
- Email addresses are normalized (lowercased) for suppression and verified-sender identity, so a
  suppression on `bad@x.io` also blocks `Bad@X.IO` (no case-based fail-open) and a verified
  `From@Acct.com` matches a send from `from@acct.com`.
- Sender-verification emails are rate-limited per `(account, email)` (a re-request within ~60s
  returns 429), preventing an authenticated member from amplifying mail at an arbitrary recipient.
  The verification token is matched in constant time, and the multipart MIME boundary is now random
  (not timestamp-derived) so it cannot be guessed to forge a MIME part.
- The HTTP providers CRLF/ASCII-control-char-reject every header-bound value (from/to/subject/
  reply_to) before it enters the provider JSON body, and SES requests are SigV4-signed over the exact
  payload bytes. Sender-identity verification and suppression are tenant-scoped and parameter-bound
  (no cross-account verification; no SQL interpolation of recipient addresses). Verified-sender +
  suppression enforcement is a `ctx.mail()`-layer policy (not a `Mailer.send` vtable guarantee).
- The framework owns email header safety for `ctx.mail()`: recipient/`reply_to` address
  validation and CRLF / ASCII-control-char rejection in `to`, `subject`, and `reply_to`
  happen in the framework (`mail/send.zig`) before any byte reaches a backend or a durable
  queue row — consumers neither have to nor should re-roll header-injection defenses.
  `enqueue` validates up front, so a malformed or injection-bearing message fails at the
  call site rather than later inside a worker.
- Custom topics default to **public signal channels** (anyone, including anonymous sockets, may
  subscribe) — exactly the existing `__features` behavior. Keep private/per-subject state
  **signal-only** and re-fetch it over an authenticated GET; payload-carrying `broadcast` is an
  explicit opt-in for data that is safe for every subscriber of the topic.
- The `.realtime.canSubscribe` guard gates private custom channels — returning `false` denies the
  subscription before it is registered.
- The custom-topic subscribe path is strictly scoped to topics that are **not** collections, so it
  can never be used to subscribe to (or receive records from) a real collection's topic without
  that collection's normal per-record authorization. Custom-topic frames are delivered verbatim
  with no per-record viewRule, since subscription was already authorized at subscribe time.
- The `path_secret` guard compares the submitted secret to the stored value in **constant time** (`crypto.timingSafeEql`), so a wrong secret leaks no byte-position timing oracle, and a mismatch returns a **bare 404** by default (`.on_mismatch = .not_found`) — indistinguishable from a non-existent route, with no existence oracle. Rotation is immediate: write a new secret to the source and every link carrying the old one stops working (404). An empty/absent stored secret fails closed (never matches).
- Per-route rate-limit buckets key on the trust-proxy-honored client IP (`ZIGBASE_TRUST_PROXY`): when proxies are untrusted a spoofed `X-Forwarded-For` resolves to an empty IP, so it cannot evade or poison another client's bucket. A denied request returns `429` with a `Retry-After` header.
- The shared one-time-code timing-safe comparison was promoted to `crypto.timingSafeEql` (the OTP auth method now calls it) so every secret comparison in the codebase uses one audited, constant-time primitive.
- Webhook bodies can be HMAC-SHA256 signed (`WebhookOpts.sign`): the receiver verifies authenticity by recomputing `hex(HMAC-SHA256(secret, "<timestamp>.<body>"))` against the `X-Signature` header (timestamp in `X-Webhook-Timestamp`), and the signed timestamp limits replay.
- Each webhook delivery carries a stable 128-bit `Idempotency-Key` header generated once at enqueue and reused across every retry/replay, so receivers can dedupe at-least-once deliveries. TLS certificate verification stays on for all webhook requests.
- Retry backoff (including a server-supplied `Retry-After`) is capped at the queue's `max_ms`, so a hostile or misconfigured receiver cannot park a worker thread indefinitely (e.g. via a huge `Retry-After`) and starve the background pool.

### Internal

- CI now runs a `-Ddev-clock=false` prod-gate test pass in the `unit` job. Previously, the five inverse-gated tests asserting that `ZIGBASE_FAKE_NOW`, `ZIGBASE_FAKE_SEED`, and test-capture are compiled out of production builds were skipped in the only CI test run and never executed.
- e2e test harnesses (`clients/typescript`, `examples/{blog,golfsim,plugins}`) now retry server startup on a port-bind race: each attempt picks a fresh OS-assigned free port, watches for the child exiting early (the zap `ListenError` bind failure) to retry immediately rather than waiting out the health deadline, and cleans up the failed process + temp data-dir between attempts (up to 5). Fixes the intermittent `ListenError` → "server did not become healthy" flake in the `ts-sdk`/`browser` CI jobs.
- PostgreSQL backend, admin/client-codegen parity (#159, Wave B, PR-8): `src/api/health.zig` derives the backend label from the live pool via `db.poolBackend` (defaulting to `"sqlite"` for pure-handler unit tests with no app); `src/codegen/acquire_datadir.zig` routes a `postgres://` target to `db.Db.openPostgres` behind the comptime `-Dpostgres` gate (postgres:// URIs never logged — they may carry credentials) and otherwise opens `<dir>/data.db` exactly as before. New live-PG codegen parity tests (`src/backend/postgres/codegen_pg_test.zig`, skip when no PG) prove the data-dir adapter opens a postgres:// source end-to-end and that the generated client matches the SQLite output byte-for-byte. The admin SPA + codegen core are untouched (both already backend-neutral). Default (`-Dpostgres=false`) build behavior is unchanged.
- PostgreSQL backend, auth / oauth / analytics / webauthn / session / challenge dialect-ization (#159, Wave B): routed every placeholder-bearing `prepare` in the **token-verification core** (`src/auth.zig` — `verifyToken`/`verifyTokenOfTypes`, hit on every authenticated request: the auth-record key+epoch read, the table-mode `_sessions` gate, and the `_superusers` lookup), the auth handlers (`src/api/auth.zig` — identity lookup, sessions, single-use tokens), `src/api/oauth.zig` (server-side `state`, external-auth links), `src/analytics/analytics.zig` (event capture, `_rollup_*` aggregation, the `_kv` watermark), `src/auth/challenge_store.zig`, and `src/auth/webauthn/store.zig` through a shared lowering helper. Before this, these subsystems still emitted SQLite's anonymous/`?N` placeholders + `datetime('now')`/`strftime(…,'now')` and called `conn.prepare` directly, so they failed at prepare on a Postgres connection — a user could log in but their token could not be VERIFIED on any later request (record CRUD already worked after PR-3; these auth/oauth/analytics paths did not).
- New `param_sink.lowerStmtZ` (`src/sql/param_sink.zig`) is the single chokepoint: it substitutes the two server-`now` expressions (`datetime('now')` → `Dialect.nowTextExpr`, `strftime('%Y-%m-%dT%H:%M:%SZ','now')` → `Dialect.nowIso8601Expr`) and renumbers `?`/`?N` placeholders to `$n` (reusing the PR-3 `ParamSink`). On SQLite it returns the input slice verbatim, so the default `-Dpostgres=false` build is byte-identical. Each subsystem gets a small per-file `prep(conn, sql)` wrapper that lowers then prepares; the lowered SQL lives in a transient `ArenaAllocator` (no fixed size ceiling) that `Db.prepare` copies out of.
- Analytics watermark portability: the incremental rollup advanced over SQLite's implicit `rowid`, which Postgres has no analog for (and the app `id` is a random base36 string, not monotonic). A new additive migration `0017_events_seq` adds a `_seq BIGINT GENERATED ALWAYS AS IDENTITY` column to `_events` on Postgres (its own migration number, not folded into 0015, so a PG database that already applied 0015 still gets `_seq`), and `analytics.seqCol` selects `rowid`/`_seq` per backend, so the same exact-window aggregation (no double-count, no drop) holds on both. The time-bucket expression and the `_rollup_*` summary `value` column are dialect-branched (`left(occurred_at,…)` vs `strftime`; `BIGINT` vs `INTEGER`). The rollup UPSERT qualifies every `"value"` reference (`"<table>"."value"` for the existing row, `excluded."value"` for the conflict source, `count(*) AS "value"` for the aggregate) — Postgres rejects the bare unqualified form as ambiguous in `ON CONFLICT DO UPDATE`; the qualified form is valid on both backends.
- Live PostgreSQL end-to-end tests (`src/backend/postgres/auth_pg_test.zig`, `-Dpostgres=true`, skip when no PG): a token mint **AND VERIFY** round-trip through `auth.verifyToken` (epoch-mode, table-mode `_sessions` gating incl. a fail-closed missing-session reject, and superuser auth), an auth round-trip (create a `users` auth collection + record, identity lookup, argon2 credential check, single-use token consume + replay rejection, session insert/list/delete), an oauth `state` single-use consume + external-auth link round-trip, and an analytics event-insert + incremental rollup (run twice to cover the `ON CONFLICT DO UPDATE` path) proving the `_seq` watermark advances without dropping or double-counting. SQLite behavior, fail-closed/single-use semantics, and parameter binding are unchanged. (`mail/*` remains deferred to a later wave.)
- PostgreSQL backend foundation, part 2 (#159, PR-1b): wired the pure-Zig PostgreSQL driver (PR-1a) into ZigBase's database seam. `db.Db`/`db.Stmt` are now runtime-selectable **tagged unions** over the SQLite backend (the former `src/db.zig` body, relocated verbatim to `src/backend/sqlite/`) and the Postgres backend, and `db.Pool` is a struct-over-union (so `acquireWriter` keeps returning `*Db`). The whole Postgres arm is comptime-gated behind `-Dpostgres`; with the flag **off (the default) the seam aliases the SQLite types directly**, so every call site resolves to the same SQLite code path. The backend is chosen once at startup from the connection string — a `postgres://…` `ZIGBASE_DB_URL` opens PostgreSQL (only in a `-Dpostgres` build), anything else opens the SQLite `data.db` as before. **The default-build SQLite data path is behavior-unchanged**, but a stock (`-Dpostgres=false`) binary now reads `ZIGBASE_DB_URL` and **logs a prominent warning** if it is a `postgres://` URL (rather than silently writing to local SQLite) — a data-misdirection safeguard. (This is why the default binary is no longer byte-for-byte identical to the pre-#159 build; the SQLite type/mapping refactor itself folds to identical code, the warning is the only added behavior.)
- Added a SQL **dialect layer** (`src/sql/dialect.zig`): a `Dialect` (SQLite + Postgres impls) centralizing the flavor-specific SQL fragments — `placeholder` (`?` vs `$n`), `nowExpr`/`nowIso8601Expr`, `sqlType` (the field storage-class → column-type mapping, now the home of the former `schema.Field.sqlType` logic, keyed on a new backend-neutral `Field.storageClass`), `likeOp` (`LIKE`/`ILIKE`), `collateNocase`, `nullsOrder`, `insertVerb`/`onConflictDoNothing`, `castExpr`, and `ttlExpiredPredicate`. Established now; the per-call-site adoption across the query/DDL layers is the parity PRs (PR-2/PR-3).
- Proved the seam end-to-end: a `-Dpostgres=true` smoke opens a `db.Pool` against a real PostgreSQL and runs exec/prepare/`$n`-bind/step plus a transaction **through the union `db.Db`** (not the driver directly), asserting the backend + dialect selection. Runs in the existing `postgres` CI job; skips where no PG is reachable. No parity features (CRUD/migrations/FTS/vector) are ported yet — that is the next wave.
- PostgreSQL backend, deterministic test-clock parity (#159, PR-7): the
  `ZIGBASE_FAKE_NOW` frozen clock now freezes the **SQL** clock on the Postgres arm too,
  matching SQLite. The two SQLite-only shims have no remote-server analog —
  `src/clock_sql.zig` shadows SQL date/time *functions* and `src/clock_vfs.zig` is a SQLite
  VFS overriding `xCurrentTime` — so their effect is reproduced on Postgres with a single
  **session-level `now()` override** (`src/backend/postgres/clock.zig`): when a freeze is
  active, every connection (opened through `pg.Db.open`, covering the pool's writer and all
  readers) installs a `zigbase_frozen.now()` wrapper returning the frozen instant and appends
  `zigbase_frozen, pg_catalog` to its `search_path` so unqualified `now()` resolves to the
  wrapper (Postgres searches `pg_catalog` implicitly-first unless it is named explicitly
  later). This freezes the dialect's `now()`/`nowIso8601Expr` (record autodate stamps,
  KV/`_migrations`/`_collections` metadata timestamps) and a consumer's raw `now()` alike,
  while leaving table/type resolution and object creation targeting the original first schema.
  Gated by the same comptime `dev_clock` build option as the SQLite shims (comptime-dead +
  never installed on a production build); the SQLite `clock_sql`/`clock_vfs` paths are
  unchanged. This is the prerequisite for the existing `ZIGBASE_FAKE_NOW` determinism tests to
  run on the `-Dpostgres` CI job. Verified end-to-end against a live PostgreSQL: a
  `now()`/`nowIso8601Expr`-stamped column reflects the frozen instant when `ZIGBASE_FAKE_NOW`
  is set, and tracks the real wall clock when it is not.
- PostgreSQL backend, CRUD + query dialect + the `$n` ParamSink rework (#159, PR-3): made record CRUD and the `records.list` query path emit Postgres-correct SQL through the merged dialect, and reworked placeholder threading from SQLite's anonymous `?`/numbered `?N` to Postgres's `$1..$n`. A new **`ParamSink`** (`src/sql/param_sink.zig`) owns one running placeholder counter and renumbers a statement's placeholders at the prepare boundary — `?` → `$next` in left-to-right (bind) order, `?N` → `$N` — preserving the exact bind ordering across the FULL predicate stack (filter, access-rule, ability `IN (?,…)`, tenant scope, TTL, FTS `MATCH`, and the vector embedding that sits **between** the WHERE params and `LIMIT`/`OFFSET` in OFFSET mode). On SQLite the renumber is a no-op that returns the original slice, so the default `-Dpostgres=false` build is byte-identical. The fragile WHERE→vector-ORDER-BY→LIMIT/OFFSET ordering is pinned by a deterministic unit test.
- Dialect-ized the CRUD/query SQL it touches: `now()`/ISO-8601 timestamps on create/update (`Dialect.nowIso8601Expr`), `RETURNING` lifecycle (portable, kept), the filter `~`/`!~` operators lower to `ILIKE`/`NOT ILIKE` on Postgres (`Dialect.likeOp`), keyset/ORDER BY emit explicit `NULLS FIRST/LAST` to match SQLite's implicit NULL placement (`Dialect.nullsOrder`), the TTL read-visible / GC-delete predicates (`Dialect.ttlVisiblePredicate`/`ttlExpiredDeletePredicate`), and the empty-set `IN ()` / empty-membership / empty-FTS / keyset never-true short-circuit now emits the dialect's constant-false (`Dialect.constFalse` — SQLite `0`, Postgres `false`, since `WHERE 0` is invalid on Postgres). Threaded the dialect into `query/compiler`, `query/sort`, `query/keyset`, `authz/abilities`, and the `records.zig`/`rules.zig` SQL builders. Fail-closed authz, parameter binding, and identifier gating are unchanged.
- Live cross-backend tests (`src/backend/postgres/crud_tests.zig`, `-Dpostgres=true`, skip when no PG): CRUD round-trip with ISO timestamps + `RETURNING`, a multi-param filter, `ILIKE` case-insensitivity, keyset pagination across a NULL boundary (NULLS FIRST), the WHERE-params-then-LIMIT/OFFSET bind ordering, a boolean round-trip (stored as `BIGINT` 0/1), and the empty-set `IN ()` → 0 rows — each asserting parity with the SQLite arm where applicable. (Keyset pagination is asserted via collation-independent score sequences; the byte-order `COLLATE "C"` text-column collation that keeps the `id` tiebreaker matching SQLite's BINARY ordering is provided by the PR-2 provisioning DDL (#169) — these tests source it from the same `Dialect.textCollate()` helper.)
- Foundation for the PostgreSQL backend (#159, PR-1a): a **pure-Zig PostgreSQL v3 wire-protocol driver** under `src/backend/postgres/`, gated behind a new `-Dpostgres` build option (default **off**, mirroring `-Dvector`/`-Ddev-clock`). The driver uses only Zig 0.16 `std` — TLS via `std.crypto.tls.Client`, SCRAM-SHA-256 (SASL) via `std.crypto` (`pbkdf2`/`HmacSha256`/`Sha256`) — so there is **no** libpq, C, or OpenSSL dependency, and the default build links zero new symbols and stays byte-identical. It connects over TCP, negotiates TLS via `SSLRequest` (`sslmode=disable`/`prefer`/`require`), authenticates with SCRAM-SHA-256 (with cleartext/md5 fallbacks), and exposes a `Db`/`Stmt`/`Pool` surface that mirrors the SQLite `src/db.zig` exactly (1-based `$n` binds via the extended Parse/Bind/Describe/Execute/Sync protocol, TEXT result decoding, transactions, `changesCount`, an N-connection pool that closes desynced/broken connections instead of recycling them, and a minimal LISTEN/NOTIFY hook). A `DriverKind` comptime seam leaves room for a future optional libpq-backed driver. This PR ships the **driver only**; wiring it into a runtime-selectable tagged-union `Db` is PR-1b. Live driver tests run against a real PostgreSQL (TLS + SCRAM verified end-to-end) in new `postgres` (plaintext+SCRAM) and `postgres-tls` (server-TLS, `sslmode=require`) CI jobs; the SQLite jobs are unchanged.
- **Security note (PG transport is un-authenticated until verify-full lands):** the wire driver encrypts transport but does not yet verify the server certificate chain/hostname in any sslmode — `prefer` is MITM-strippable to plaintext and `require` encrypts without authenticating the server (libpq-`require` parity). `verify-ca`/`verify-full` are now **rejected** at parse time rather than silently downgraded. Real `verify-full` certificate + hostname verification is the immediate tracked follow-up; until then use the PG backend only over a trusted network path.
- Live `-Dpostgres` round-trip tests (`src/backend/postgres/dumpload_pg_test.zig`, skip when no PG): a SQLite instance with two related collections, an encrypted field, and a system-table row migrates into a throwaway Postgres schema — asserting identical per-table row counts, that the encrypted envelope still decrypts, that the relation FK is enforceable on Postgres, and that ids/metadata are preserved; plus an injected mid-load failure that rolls the whole load back to zero migrated rows. Backend-neutral tests in `src/dumpload.zig` cover the rollup-watermark reset and that per-table report counts equal the real target counts.
- PostgreSQL backend parity (#159, PR-5): verified field-level encryption + key-rotation rewrap on the Postgres arm. Field encryption is pure-Zig AEAD whose ciphertext is a backend-neutral TEXT *envelope*, so the encrypt/decrypt path needed no change; the one Postgres-incompatible spot was `src/rewrap.zig` keying its rewrap `UPDATE`s by SQLite's implicit `rowid` (Postgres has none). Rewrap now targets the app-generated string `id` PRIMARY KEY and renumbers placeholders through the dialect (`?n` → `$n`), so it runs on both backends; the SQLite behavior is unchanged (same rows targeted, in-memory rewrap unit tests pinned). Added live `-Dpostgres=true` tests (`src/backend/postgres/encryption_pg_test.zig`) that round-trip an encrypted value through the `db.Pool`/`db.Db`/`db.Stmt` stack and a real Postgres column, and exercise a full key-rotation rewrap cycle (old + new generations both decrypt, idempotent re-run, fail-closed on a missing key) — they skip where no PostgreSQL is reachable.
- PostgreSQL backend, full-text search PORT (#159, PR-10): ported the FTS surface (`src/search/fts.zig`) to Postgres behind the SAME `.searchable` schema flag and `?search=` API. On a Postgres backend, provisioning now lowers a searchable collection to a `STORED` `tsvector` **generated column** `"<col>_fts"` (`to_tsvector('simple', coalesce(c1,'')||' '||…)`) plus a **GIN index** instead of the FTS5 external-content vtable + sync triggers; `fts.ensureIndex` dispatches on the dialect and is idempotent (a marker comment on the generated column detects a searchable-column-set drift and rebuilds; a now-unsearchable collection drops the column/index). The `records.list` search branch dispatches in `fts.build`: Postgres emits `"<col>"."<col>_fts" @@ plainto_tsquery('simple', $n)` (bound term, no JOIN) and `ORDER BY ts_rank(…, plainto_tsquery('simple', $n)) DESC`, threaded through the existing `$n` ParamSink — the `ts_rank` term binds in the ORDER BY position (a new optional `Search.order_param`, ordered before the vector embedding) so the placeholder indices line up. The SQLite FTS5 path (vtable + triggers + `MATCH` + `bm25`) is unchanged and the default `-Dpostgres=false` build is byte-identical.
- The CRITICAL chokepoint invariant holds on Postgres: the search predicate AND-s into the SAME composed `records.list` `WHERE` as filter + list rule + abilities + tenant scope, so a search on a tenant-owned / ability-guarded collection returns only rows the caller may view — proven by live records.list-level tests, not just policy-layer ones.
- Live full-text-search parity tests (`src/backend/postgres/fts_pg_test.zig`, `-Dpostgres=true`, skip when no PG): tsvector provision + ranked `?search=` (multi-column title||body, NON-searchable column excluded, set-parity with the SQLite FTS5 arm), tenant-scoped search (active account only / fail-closed empty context / superuser bypass), ability-scoped search (membership-authorized rows only / fail-closed no-membership), and `ensureIndex` drift-rebuild when a field becomes newly `.searchable`.
- PostgreSQL backend, KV store / TTL-GC / sticky-experiment parity (#159, PR-4): dialect-ized the remaining KV-subsystem SQL so it runs correctly on Postgres. The built-in `_kv` settings store (`src/data.zig`) routes its upsert and reads through the dialect + the `$n` ParamSink chokepoint — `datetime('now')` → `Dialect.nowTextExpr` (byte-identical on SQLite, ISO-8601 `to_char(now())` on Postgres), the `ON CONFLICT(key) DO UPDATE` upsert targets the real `_kv` PRIMARY KEY (valid on both backends), and the prefix scan's case-sensitive `key GLOB '<p>*'` lowers to `key LIKE '<p>%'` on Postgres (SQLite's `LIKE` would be case-INSENSITIVE, so the operator must differ to keep identical semantics — new `Dialect.prefixMatchOp`/`prefixWildcard`). The sticky-experiment resolver (`src/features_resolver.zig`) lowers `INSERT OR IGNORE` → `INSERT … ON CONFLICT DO NOTHING` (`Dialect.insertVerb`/`onConflictDoNothing`) with `?N`→`$n` renumbering, and `gcExpiredAssignments` now reaps via a dialect relative-age predicate (new `Dialect.agedBeyondDaysPredicate` — `strftime` normalization on SQLite, an ISO-`Z` regex-gated compare against a `make_interval` cutoff on Postgres) addressed by the dialect physical-row column (new `Dialect.physicalRowId` — `rowid` on SQLite, `ctid` on Postgres). Both GC paths stay **fail-safe**: a NULL or malformed timestamp is never aged out. On SQLite the renumber is a no-op slice and the lowered SQL is behavior-identical, so the default `-Dpostgres=false` build is unchanged.
- Live cross-backend tests (`src/backend/postgres/kvttl_pg_test.zig`, `-Dpostgres=true`, skip when no PG): a `_kv` set/get/delete round-trip with upsert-preserves-`created` and the prefix scan, the `gcExpiredAssignments` fail-safe (an aged row reaped, a future row kept, a malformed-timestamp row NOT reaped), and a sticky experiment that persists + survives a weight change on Postgres. The in-memory rate limiter (`src/ratelimit.zig`) carries no SQL and needs no backend work; the stateful-cursor store was already dialect-ized in PR-3.
- PostgreSQL backend, realtime parity + cross-instance fan-out (#159, PR-6/PR-6b): made the realtime change-feed work on Postgres and, crucially, **across app instances** sharing one database. The change-feed itself was already backend-agnostic (after-commit dispatch → facil.io in-process pub/sub; no `update_hook`/triggers/WAL polling), and the per-subscriber delivery authz (`realtime/hub.zig` `shouldDeliver` → `policy.matchesRule`) already composes the view/ability/tenant predicates through the dialect, so create/update delivery authorizes against the live row with Postgres-correct `$n`/`now()` SQL unchanged. The one historically SQLite-coupled spot — the **delete-snapshot** authz sandbox (`hub.matchesSnapshot`, which evaluates an owner/expression-scoped `viewRule` against the deleted row's snapshot in a throwaway in-memory DB) — needs no `:memory:` Postgres analog: `db.Db.openMemory()` is **always** the SQLite union arm (SQLite is compiled into every build), so the snapshot sandbox is a self-contained SQLite-dialect rule evaluator that never touches the live DB and works identically whichever backend is live. Documented + pinned with live-PG tests.
- Cross-instance delivery via Postgres **LISTEN/NOTIFY** (`src/realtime/pg_bridge.zig`): on the same after-commit dispatch, the writer additionally issues `NOTIFY zigbase_rt, '<payload>'` carrying a **minimal, fixed-size** `{origin, collection, action, id}` body. Every process runs **one dedicated listener connection** (`startRemoteListener`, spawned just before `zap.start`) that consumes notifications and re-feeds the EXISTING in-process hub: create/update re-fetch the live row, then `WS.publish` runs each local subscriber's unchanged `onChannelMessage` authz. A per-process **origin id** tags every NOTIFY so the listener skips its own writes (the writing instance already delivered in-process — no double delivery). The listener **auto-reconnects with capped backoff and loud logging** on a connection drop (PG restart/failover) instead of silently stopping. Logical decoding was rejected as operationally heavy and authz-bypassing overkill given the clean after-commit hook.
- **No row data on the NOTIFY wire (security).** Deletes authorize against the gone row's snapshot, but putting that snapshot in the `NOTIFY` payload would broadcast the row's columns — including the **decrypted plaintext of `.encrypted` fields** — to any DB role that can `LISTEN` (CONNECT-only, no SELECT/RLS grants needed), defeating ciphertext-at-rest. Instead the writer stores the deleted row's **at-rest (ciphertext)** snapshot in a PG-only side table `_rt_delete_snapshots` (migration 0018) keyed by a random token, and the `NOTIFY` carries only that token (also keeping the payload fixed-size — no 8000-byte overflow). The receiving instance reads the snapshot back over its own authenticated DB connection (`records.getAtRest` captures the row without decrypting). This also closes **forged-NOTIFY deletes**: a fabricated token has no side-table row, so the delete is never delivered. Orphaned tokens are GC'd by a short TTL the writer sweeps on insert.
- **Consistent delete authz across paths.** Delete authorization evaluates the deleted row's `viewRule` against the **at-rest (ciphertext)** snapshot on every path — local in-process and cross-instance — matching the live create/update path (which compares the ciphertext column), so a rule referencing an `.encrypted` field authorizes a delete identically everywhere. The local path captures the at-rest snapshot (`records.getAtRest`, via `ws.prepareDelete`) only when it could differ from the decrypted one (the collection has an encrypted field) or when the cross-instance side table needs it (Postgres); otherwise it reuses the snapshot it already read, so SQLite with no encrypted fields takes **no extra read** and stays byte-identical. The delivered delete frame is id-only on every path, so the representation choice never changes what subscribers receive.
- **Gated cleanly:** NOTIFY/LISTEN + the side table only apply when the active backend is Postgres (self-gated via `db.poolBackend`); the new `db.Db` seam helpers (`dbListen`/`dbNotify`/`dbWaitNotification`) are comptime no-ops on SQLite, and migration 0018 is a no-op there. SQLite stays single-process and **byte-identical** — the in-process `broadcast` path is behavior-unchanged (refactored only to share a `publishFrames` core with the listener; the common delete path with no encrypted fields takes no extra read/write), confirmed by the realtime browser suite.
- Live cross-backend tests (`src/backend/postgres/realtime_pg_test.zig`, `-Dpostgres=true`, skip when no PG): owner-scoped + `@public` + locked create/update/delete delivery authz on a real Postgres collection; the delete-snapshot path with the row absent from PG; the cross-instance path proper — a delete token stored on connection A, `NOTIFY`'d, read back from the shared side table on connection B and authorized for B's subscribers (incl. a forged-token rejection); and a **no-plaintext** guard proving a delete of a row with an `.encrypted` field puts neither the plaintext nor the ciphertext on the `NOTIFY` wire (token only) while the side-table snapshot holds ciphertext and the remote authz still resolves. Plus `pg_bridge.zig` codec unit tests (run in the default build too).
- PostgreSQL backend, schema/DDL + migration parity (#159, PR-2): dialect-ized `src/ddl.zig` (column types, collation, FK/index DDL via `Dialect.sqlType`/`collateNocase`) and gave `ddl.rebuildPlan` a Postgres path that emits in-place `ALTER TABLE ADD/RENAME/ALTER TYPE/DROP COLUMN` keyed off the same stable-field-id matching (instead of SQLite's create-`__new`+copy+drop+rename rebuild), preserving data. Routed `provision.zig`'s type diff + the `_collections` CRUD in `src/collections.zig` through the dialect (now-as-text, `?N`→`$n` placeholder rewrite, quoted mixed-case identifiers, SQLite-only PRAGMA guards). Ported all 16 system migrations to emit backend-correct SQL from the SAME code via a new `Migrator.execLowered` (`INTEGER`→`BIGINT`, `datetime('now')`→a text now, `INSERT OR IGNORE`→`ON CONFLICT DO NOTHING`, `AUTOINCREMENT`→identity). FTS5 provisioning is skipped on Postgres (its tsvector port is a later PR). New dialect helpers (`nowTextExpr`, `autoIncPk`, `renumberPlaceholders`, `lowerMigrationSql`) and `db.dbDialect`/`dbBackend` accessors. Added live-PG tests (gated under `-Dpostgres`, skip without a reachable server): all 16 migrations + full comptime-schema provisioning on a fresh database, plus an additive-field-add rebuild that preserves data via `ALTER`. The default `-Dpostgres=false` build and SQLite DDL/migration behavior are unchanged.
- Postgres provisioning collation parity (#159): TEXT columns are provisioned with `COLLATE "C"` so text `ORDER BY` / keyset pagination (notably the `id` tiebreaker) yields the SAME byte order as SQLite's default BINARY collation — cross-backend pagination stays deterministic. **Caveat:** a `.nocase` (case-insensitive) index currently provisions **case-SENSITIVELY** on Postgres (it has no built-in NOCASE collation; the `lower()`/citext fix is a tracked pre-GA follow-up) — so a consumer's `.nocase` UNIQUE index does NOT reject case-variant duplicates there. Provisioning logs a prominent startup warning for every `.nocase` index under Postgres so the weakening is never silent. The built-in auth identity index is a plain partial-unique (NOT `.nocase`) and is unaffected — identical on both backends.
- PostgreSQL backend, vector / nearest-neighbor search PORT (#159, PR-11): ported the opt-in vector surface (`src/search/vector.zig`) to Postgres behind the SAME `?vector=<field>[:cosine|:l2]:<embedding>` API and the SAME `-Dvector` build flag — one flag now enables KNN on BOTH backends (sqlite-vec on SQLite, pgvector on Postgres; pgvector has no C to compile, so no second build flag). `vector.build` dispatches on the dialect: Postgres casts the JSON-embedding column + the bound query embedding to the `vector` type at query time (`("<col>"."<field>")::vector <=> $n::vector` for cosine, `<-> ` for L2) and orders nearest-first, threaded through the existing `$n` ParamSink. The embedding stays in an ordinary JSON field — no schema change, no `vector(N)` column, a brute-force scan exactly symmetric with sqlite-vec's scalar `vec_distance_*` (no ANN index either side; an indexed `vector(N)` + ivfflat/hnsw variant, which would need a `dims` field option, is a documented future enhancement). Provisioning runs `CREATE EXTENSION IF NOT EXISTS vector` once at startup (best-effort: a role lacking privilege warns and continues rather than aborting), so the target PostgreSQL must have pgvector available. The SQLite sqlite-vec path is unchanged and the default (`-Dvector=false`) build is byte-identical.
- The CRITICAL chokepoint invariant holds on Postgres: the vector distance ORDER BY runs over the WHERE-filtered set — its `WHERE … IS NOT NULL` fragment AND-s into the SAME composed `records.list` `WHERE` as filter + list rule + abilities + tenant scope (NOT a pre-WHERE k-NN that bounds rows before scoping), so a vector search on a tenant-owned / ability-guarded collection returns only rows the caller may view even when the globally-nearest row belongs to another tenant — proven by live records.list-level tests, not just policy-layer ones.
- Live pgvector parity tests (`src/backend/postgres/vector_pg_test.zig`, `-Dpostgres=true -Dvector=true`, skip when no PG or no pgvector): `?vector=` KNN ranks correct nearest-neighbor order via `<->`/`<=>` (cross-backend exact-L2 golden against the SQLite sqlite-vec arm), tenant-scoped vector search (active account only / fail-closed empty context / superuser bypass returns the globally-nearest row), and ability-scoped vector search (membership-authorized rows only / fail-closed no-membership). Verified green against PostgreSQL 14 + pgvector 0.8.0.
- New `policy.zig` authorization composition layer wrapping the `rules.zig` primitive. Every enforcement chokepoint (REST list/view/create/update/delete, realtime delivery, subscribe-authorization) now routes through `policy.*` so later work can compose ability/tenant predicates at one place. PR1 is a byte-identical pass-through, pinned by back-compat tests.
- Release process: GitHub release descriptions now contain only the released version's changelog section (via the new `scripts/extract-release-notes.sh`), not the entire `CHANGELOG.md`. Both `release.yml` and `scripts/release.sh` use per-version notes.

## [0.8.0] - 2026-06-28

### Breaking

- **Feature flags are now declared-only.** Flags must be declared in the `App(.{ .flags = .{ … } })` literal; only declared flags resolve. The v0.7 runtime-string API `ctx.flag("arbitrary")` (KV-or-false) has been **removed** — use the typed `App.flag(ctx, .name)` for known flags, or `ctx.flagByName("name")` (returns `?bool`, null when undeclared) for dynamic names.
- **`ctx.setFlag` now writes a declared-flag override.** It writes the `flag:<name>` override key for a DECLARED flag and errors `error.UndeclaredFlag` otherwise (the typed, compile-checked form is `App.setFlag(ctx, .name, enabled)`). Previously it set an arbitrary `<name>` KV value.

### Features

- **Comptime feature-flag + experiment registry (#128/#129/#130).** Declare `.flags` (bare-bool default or `.{ .default, .description }`) and `.experiments` (`.{ .variants, .weights, .sticky, .description }`) in the `App(cfg)` literal. Malformed declarations (unknown sub-key, non-bool flag, variants/weights length mismatch, empty/duplicate variants, all-zero weights) are loud `@compileError`s.
- **Typed, compile-checked accessors.** `App.flag(ctx, .name) bool`, `App.setFlag(ctx, .name, enabled) !void`, and `App.experiment(ctx, .name, subject) ![]const u8` — a typo'd flag/experiment name is a compile error (generated `App.Flag` / `App.Experiment` enums).
- **Runtime resolution.** `ctx.flagByName(name) ?bool` (dynamic read), `ctx.flags().resolveAll(subject)` resolves every declared flag + experiment in a single batched `_kv` scan, and deterministic experiment bucketing (`FNV1a-64(name ++ 0x00 ++ subject)` over cumulative weights) gives a stable variant per `(name, subject)`. Per-flag overrides live in `_kv` under `flag:<name>`; experiment weight overrides under `exp:<name>:weights` (JSON).
- Admin UI gains a **Feature Flags & Experiments** screen (`/_/#/features`) showing every declared flag (name, default, description, effective value) with a toggle to set/clear the `flag:<name>` override, and each declared experiment's variants with editable weight sliders that write the `exp:<name>:weights` override; a "Reset to declared" action clears the override. Superuser-only; backed by the new `GET /api/features` endpoint.
- New `GET /api/features` endpoint (superuser) returns the comptime-declared flag + experiment registry alongside each entry's current `_kv` override — useful for custom admin tooling.
- Feature exposure events: register `.onFeatureExposure` to receive an `ExposureEvent` (`{ kind: .flag | .experiment, name, subject, value, variant }`) each time a declared flag or experiment is resolved. The hook is notify-only and zero-cost when unregistered (the resolver never builds the event without a handler).
- Realtime feature signal: any flag/experiment override change (`ctx.setFlag`/`App.setFlag` or an admin `PUT`/`DELETE` of a `flag:<name>` / `exp:<name>:weights` setting) broadcasts a signal-only `{"type":"features.changed"}` frame on the public `__features` channel. Clients may subscribe anonymously and re-`GET /api/state` on receipt; no per-subject state or experiment assignment is ever pushed over the socket.
- **Public feature-state endpoint (#130).** `GET /api/state?subject=<id>` is an **unauthenticated**, read-only projection of resolved flags + experiments: `{ "flags": { "<name>": <bool>, … }, "experiments": { "<name>": "<variant>", … } }`. It exposes resolved values ONLY — never the `_kv` keys, defaults, weights, timestamps, or any superuser settings verb (those stay behind `requireSuperuser`). A `.sticky` experiment returns its persisted assignment here too (agreeing with `App.experiment`), resolved **reader-first** so a caller-supplied subject can't storm the writer lock. Auto-mounts at `/api/state`; configure with `.features = .{ .public_route = "/state" }` to remap or `.{ .public_route = .disabled }` to turn off.
- **Typed `zb.flags.resolveAll(subject)` in the TypeScript SDK.** `zig build gen-client` now emits a fully-typed feature-state surface from your `App(.{ .flags, .experiments })`: flags as named `boolean`s and each experiment as a string-literal union of its declared variants (`FeatureState`). `await zb.flags.resolveAll("user-42")` calls `GET /api/state` and returns `{ flags: { … }, experiments: { … } }` with no `any`. Emitted only when flags/experiments are declared; the runtime-introspection tier omits it (no comptime metadata), matching typed routes and custom auth methods.
- Sticky experiment assignments (#129): declare an experiment `.sticky = true` to persist a subject's first variant in `_experiment_assignments` so it **survives later weight changes** (new subjects still follow the current weights; empty subjects are never persisted). A framework-internal `_experiment_gc` job — installed only when a `.sticky` experiment is declared — reaps assignments older than the new `.experiment_assignment_ttl` config (in days, default `90`) hourly in bounded batches.

## [0.7.1] - 2026-06-28

### Features

- TypeScript client codegen now emits **precise typed I/O for custom auth methods**. Enable a custom method in the new struct form — `.custom = &.{ .{ .slug = "corp-sso", .Initiate = .{ .Input = …, .Output = … }, .Complete = .{ .Input = …, .Output = … } } }` — and `zig build gen-client` reflects the declared Zig types into `zb.auth.<col>.<method>.{initiate,complete}` interfaces (named by the Zig type, like the typed `zb.rpc.*` route surface). A `void` Input omits the input argument; a `void` Output maps to `Promise<void>`. Bare-string slugs (`.custom = .{"slug"}`) stay fully back-compatible and untyped. Typed customs are a build-time feature (the runtime-introspection typegen tier keeps them untyped, exactly like typed routes).

### Fixes

- Exported `zigbase.Tx` — the transaction scope passed to a `ctx.tx(T, fn(*Tx) ...)` callback. It was referenced in the docs but never re-exported from the public API, so consumers could not name the callback's parameter type.
- The comptime per-auth-method `.rate_limit = .{ .custom = .{ .max = …, .window_s = … } }` config form now compiles (it previously failed with a `@tagName`-on-a-struct error; only the `.default`/`.off` enum-literal forms worked).
- The TypeScript client generator (`zig build gen-client`) no longer hits the comptime branch-quota limit on apps with larger custom-route tables.

### Internal

- golfsim example: added demos for per-device session management (`.session_store = .table` + `ctx.auth().revokeAllSessions`/`listActiveSessions`/`revoke`), an atomic hold→booking convert via `ctx.tx()`, a best-effort booking-confirmation webhook via `ctx.http()`, and KV write-side seeding from `onBootstrap`. Added a deterministic e2e suite that freezes time with `ZIGBASE_FAKE_NOW` and captures the outbound webhook. Fixed a latent date-formatting bug in golfsim's `isoFromEpoch` (signed-integer `{d:0>N}` emitted a `+` sign, breaking hold creation).
- plugins example: demonstrates the comptime `.rate_limit = .{ .custom = … }` per-method config, and documents field-key rotation (`ZIGBASE_FIELD_KEY_V<n>` + `zigbase rewrap`) in its README.

## [0.7.0] - 2026-06-28

### Breaking

- Custom handler/hook/job signatures now receive a unified per-request `*Ctx`:
  - Untyped routes are `fn(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response` (was `fn(*RouteEvent)`).
  - Record hooks are `fn(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void` (was one-arg `fn(*RecordEvent)`).
  - Jobs are `fn(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void` (was one-arg `fn(*JobEvent)`).
  - Lifecycle hooks are `fn(ctx: *zigbase.Ctx, ev: *zigbase.events.LifecycleEvent) void`.
  - Typed routes keep `fn(req: *zigbase.Req(In)) zigbase.RouteError!Out`, but reach capabilities via `req.ctx` (`req.ctx.records()`, `req.ctx.http()`, `req.ctx.arena`, `req.ctx.app`).
- DB access is now uniform through the `Ctx` capability object: `ctx.records()` (list/get/create/update/delete), `ctx.tx()` (atomic writes), and `ctx.http()` (outbound client). In a `before*` hook, `ctx.records()` is bound to the triggering write's in-transaction connection, so a side-write commits/rolls back atomically with it.
- Removed `RecordEvent.data`, `JobEvent.reader()`/`JobEvent.writer()`, `ev.caps()`, and the public `zigbase.Data` re-export. Migrate hook/job DB access to `ctx.records()`; for raw SQL on a migration-owned table use the pooled writer via `ctx.app.pool.acquireWriter()`.

### Features

- `ctx.tx(T, fn)` runs several record writes in one atomic transaction — all
  commit, or all roll back on any returned error. The callback receives a `*Tx`
  whose `t.records()` exposes the full `Records` API; all writes share the
  in-transaction connection with no deadlock. Nesting is rejected immediately
  (`error.NestedTransaction`).
- Admin UI now includes a "Settings / Feature Flags" section (`#/settings`) where
  superusers can list, create, edit, and delete KV entries, and toggle boolean feature
  flags with a checkbox — backed by the existing `/api/settings` REST surface.
- Auth lifecycle hooks (#98): a new `.auth` config group adds **before/after** hooks for
  `register`, `logout`, `refresh`, and `password-change`, extending the Theme D
  `beforeAuthSuccess` discipline into a uniform lifecycle. Before-hooks run with a `*Ctx`
  bound to the action's connection (in-transaction for register / refresh /
  password-change), so `ctx.records()` writes commit atomically with the action; returning
  an error aborts and fails closed (rolling back where a write transaction exists — e.g. an
  aborting `beforePasswordChange` leaves the password unchanged and the reset token
  un-consumed, an aborting `beforeRegister` creates no account). After-hooks are notify-only.
  Hooks fire on `register` (auth-collection record create), `POST …/auth-logout`,
  `POST …/auth-refresh`, and `POST …/confirm-password-reset`. A typo'd hook name or a
  wrong-typed handler is a compile error. The existing `beforeAuthSuccess` and `onAuth`
  hooks are unchanged.
- Handler/hook/job capability object: handlers, hooks, and jobs now receive a
  `*Ctx` directly, exposing `ctx.records()` (filtered/sorted/paginated list +
  get/create/update/delete, with `expand`/relations), an outbound `ctx.http()`
  client, and a standard error model (`ctx.fail`/`ctx.invalid`, error→status
  mapping over the existing `{code,message,data}` envelope). Custom handlers no
  longer need to drop to raw SQL or vendor an HTTP stack.
- **Encryption key rotation** — at-rest field encryption now supports a primary (write) key plus older read-only key generations. The primary key is `ZIGBASE_FIELD_KEY` at generation `ZIGBASE_FIELD_KEY_GENERATION` (default 1, = the `v<N>:` envelope version written); older generations are supplied via `ZIGBASE_FIELD_KEY_V<n>`. Writes use the primary generation; reads dispatch on each value's envelope version. The single-key default is unchanged and fully backward compatible.
- **`zigbase rewrap` command** — re-encrypts every `.encrypted` field across all collections under the primary key, and migrates legacy plaintext into ciphertext (the supported way to enable `.encrypted` on a column that already holds plaintext). Idempotent, transactional per collection, with `--dry-run`.
- **`ZIGBASE_FAKE_NOW` now also freezes `CURRENT_TIMESTAMP` and column DEFAULTs.** The dev-only test clock previously froze the framework's own timestamps and a consumer's raw `datetime('now')` / `unixepoch('now')` / `strftime(…, 'now')`, but the SQL keywords `CURRENT_TIMESTAMP` / `CURRENT_TIME` / `CURRENT_DATE` and column `DEFAULT CURRENT_TIMESTAMP` still read the OS clock (they go through SQLite's VFS, not the SQL-function layer). On dev builds, connections now open against a wrapping VFS — a byte-for-byte copy of the default VFS with only its current-time hooks overridden — so those keywords and defaults honor the frozen instant too, making tables with timestamp defaults deterministically snapshot-testable. All file I/O still delegates to the genuine OS VFS unchanged, and the wrapper is compiled out entirely on a production build (`-Ddev-clock=false`).
- **Seeded entropy for deterministic IDs/tokens in test mode (`ZIGBASE_FAKE_SEED`)** — set `ZIGBASE_FAKE_SEED` to a decimal `u64` on a dev build to make record/field ID and token key generation reproducible across runs with the same seed, enabling stable snapshot tests. Gated by the same `dev_clock` build option as `ZIGBASE_FAKE_NOW`: compiled out on production builds, so a production binary always uses the OS CSPRNG and cannot be seeded. Closes #95.
- Expired-session garbage collection for `.session_store = .table` (#114). Enabling the
  table-mode session store now auto-installs a framework-internal recurring job that deletes
  expired `_sessions` rows in bounded batches on the writer — no opt-in required. The default
  cadence is hourly; override it with `App(.{ .session_store = .table, .session_gc_cron = "…" })`
  (UTC, minute-granularity cron syntax). Nothing is installed in the default `.epoch` mode (no
  job, no timer — the zero-overhead guarantee is preserved).
- Session management verbs on `ctx.auth()` (#99): `revokeAllSessions()` ("log out
  everywhere"), `refresh()` (sliding re-mint, other sessions stay valid), and `rotate()`
  (bump + re-mint, keep this session and kill every other). Free-function forms
  `zigbase.auth.revokeAllSessions/refresh/rotate(ctx)`. Sessions remain stateless JWTs but
  are now **revocable** via a per-auth-record token epoch (the default
  `App(.{ .session_store = .epoch })` model) — **no extra query on either the verify hot path
  or login**: the epoch is folded into the single `tokenKey` SELECT each already performs.
  Existing valid tokens keep working: tokens minted before the epoch existed and freshly
  created records both read as epoch 0.
- New comptime config key `.session_store` (`.epoch` default, or `.table`). The `.table`
  variant adds a server-side `_sessions` store for full **per-device** management:
  `ctx.auth().listActiveSessions()` (with `is_current`) and `ctx.auth().revoke(sessionId)`
  ("log out THIS device", owner-or-superuser authorized). In table mode each token carries an
  opaque `sid` and verification additionally requires a live (unexpired) session row — one
  extra indexed read per authenticated request. `.epoch` stays the default and is unchanged:
  **zero extra DB work, and enabling `.table` does not alter the `.epoch`-mode token shape**
  (the `sid` claim is simply omitted when absent). In `.epoch` mode the per-device verbs
  return `error.SessionStoreNotEnabled`.
- **Field/collection policy pipeline** — a value-transform seam at the records read/write path, applied transparently with the field schema in hand. Its first behavior ships below.
- **Transparent at-rest field encryption** — mark a `text`/`editor`/`json` field `.encrypted = true` to store it encrypted (AES-256-GCM) in SQLite while handlers, the records API, and HTTP responses see plaintext. Encrypted fields cannot be indexed, marked `.unique`, or used in a `?filter`/`?sort` (compile error / 400). Key rotation is designed into the versioned `v<N>:` envelope.
- **TTL records.** A collection may declare `.ttl_field = "<field>"` naming an existing `date`/`autodate` field as the row's expiry timestamp. A framework-internal GC reaps expired rows automatically — once at startup and then on a 5-minute interval — across every TTL-enabled collection. Opt-in and additive; collections without `.ttl_field` are untouched.
- **Framework-internal scheduled jobs.** Added an internal scheduled-job mechanism (`scheduler.concatJobs`) so the framework can run its own jobs (such as the new `_ttl_gc` sweep) alongside consumer `.cron` jobs. The scheduler now starts whenever a TTL collection is declared, even with no user cron configured.
- Built-in key→value/settings store (#87): `ctx.kv().get/set/delete` (and the curated `data.kvGet`/`kvSet`/`kvDelete`/`kvList`) over a new internal `_kv` table — small server-managed values with no collection, schema, or access rules. Superuser-managed and not public by default.
- Typed feature flags (#88): `ctx.flag(name) -> bool` and `ctx.setFlag(name, enabled)`, a typed boolean view over the same KV store (`"true"`/`"1"` truthy, unset = false).
- Superuser-only settings HTTP API: `GET /api/settings`, `GET/PUT/DELETE /api/settings/:key` for managing KV/settings values.
- The `ZIGBASE_FAKE_NOW` dev test clock now also freezes a **consumer's own raw SQL**
  `datetime('now')` / `unixepoch('now')` / `strftime(…, 'now')` (and `date`/`time`/
  `julianday`, including their zero-argument implicit-`'now'` forms). SQLite's date/time
  builtins are shadowed on every reader and writer connection so they resolve to the frozen
  instant, while explicit datetimes and modifiers (`'+1 day'`, the `strftime` format string)
  pass through to genuine SQLite. This makes e2e/snapshot tests of consumer routes that use
  raw time SQL fully deterministic (#84). Like the rest of the test clock it is **compiled
  out of production builds** (`dev_clock` build option; off in any release build) — a prod
  binary is byte-for-byte unaffected and never reads the env var.
- **Dev-only test-mode capture for outbound mail + HTTP (`zigbase.testcapture`)** — for
  deterministic e2e/integration tests, the framework can now capture what it *sent* and
  inject canned responses: an in-memory mail **outbox** (`testcapture.mail`) records every
  `Mailer.send` (from/to/subject/body, optionally suppressing real delivery), and an HTTP
  **capture/mock** seam (`testcapture.http`) records every outbound `ctx.http()` call and
  returns canned responses matched by URL substring — with no network — mirroring the OAuth
  `Transport` injection. Tests read/assert the captures via a small API (`mail.count/get/
  find`, `http.mock/requestAt/requests`). Like the test clock, it shares the **same comptime
  gate** (`dev_clock` build option; on in `Debug`, off in any release build): on a production
  build `testcapture.enabled` is `comptime false`, both seams fold away, and the binary is
  byte-for-byte unaffected with no runtime branch or perf cost (#96).
- Auth lifecycle hook `beforeAuthSuccess` (#80): a writable, transactional, abortable hook
  that runs after credentials/token verification and **before** the session is issued, with
  a `*Ctx` bound to the login's in-transaction writer. Its `ctx.records()` writes commit
  atomically with the login; returning an error rolls them back (and, for magic-link,
  un-consumes the link token) and blocks the session (fail closed). Fires on the unified
  `POST /api/collections/:col/auth/:method/complete` endpoint (password / otp / webauthn /
  oauth2 / custom) and the magic-link `consume` link. The existing notify-only `onAuth` is
  unchanged and still fires once, after issuance. Motivating use case: claim anonymous
  records on a user's first login.
- Session management surface `ctx.auth()` with `clearSession` (#86): `ctx.auth().clearSession()`
  and `zigbase.auth.clearSession(ctx)` return the cleared `zb_auth`/`zb_csrf` cookies built
  from the framework's own cookie policy, so a logout handler is one line and can never drift
  from the built-in logout.
- TTL collections (`.ttl_field`) now exclude expired rows from **every read** (list, get, expand, `ctx.records()`). The predicate is ANDed with any filter, access rule, and keyset cursor automatically — no manual `expires_at > @now` filter needed. Semantics match the GC: `NULL` ttl = never expired; unparseable ttl = fail-safe visible; non-canonical date forms (offsets, space separator, date-only) compared correctly as instants via `strftime`.
- Typed TypeScript client for built-in auth methods: `zig build gen-client` now emits
  precise input/result types for the `client.auth.<collection>.<method>.initiate/complete`
  surface of the three built-in non-password methods, replacing the previous untyped
  `Record<string, unknown>` / `unknown` stubs. `magic_link` initiate takes `{ identity }`
  and resolves `void` (204); `otp` initiate takes `{ identity }` (→ `void`) and complete
  takes `{ identity, code }`; `webauthn` initiate takes `{ identity? }` and resolves
  `{ challenge, rpId, ceremonyId, timeout }`, complete takes
  `{ ceremonyId, credentialId, authenticatorData, clientDataJSON, signature }`. Every
  built-in `complete` resolves to `{ token }` (`AuthMethodResult`). Custom methods
  (`.custom` slugs) remain on the untyped stubs for now (a typed-I/O declaration API for
  custom methods is a planned follow-up).

### Fixes

- `before*` record hooks now run INSIDE the triggering write's transaction on the
  HTTP create/update/delete path. A before-hook's own `ctx.records()` side-writes
  and the primary row write now commit atomically, and a before-hook that returns
  an error — or a denied access-rule guard — rolls the whole transaction back, so
  a rejected write persists nothing (fail closed). Previously a before-hook
  side-write committed independently, before the triggering write.
- `ctx.records()` now allocates its results on a per-invocation arena instead of
  the long-lived process allocator. This fixes a heap leak that grew per request
  on routes and unboundedly for per-minute cron jobs. Route results live on the
  request arena; job, `App.submit`, and lifecycle-hook results live on a
  per-invocation arena freed when the invocation ends. No API change.
- **Unknown collection/field keys now fail the build.** A typo'd key in a comptime `.collections` spec — collection-level (e.g. `.ttl_filed`), under `.rules`/`.auth` (e.g. `.viewRul`), or on a field (e.g. `.requied`, `.encrypte`) — was silently ignored; it is now a `@compileError` that lists the recognized keys for that spec.
- `onError` / Sentry integration now fires only for server-side (5xx) errors; client errors (4xx) no longer trigger the error handler or Sentry reports.
- Auth methods configured with a custom `rate_limit` (`.{ .custom = .{ .max, .window_s } }`) now actually honor that `max`/`window_s` instead of silently falling back to the global limiter. Each method gets a dedicated bucket scoped by collection + method slug (keyed on the same IP/identity subject as the global limiter), so distinct methods and collections never share a budget, and a custom limit applies even when the global limiter is disabled (`ZIGBASE_RATE_LIMIT_MAX=0`).
- Uploaded files are now cleaned up when a record update fails validation, preventing orphaned files from accumulating in storage.

### Performance

- Skipped a redundant buffer duplication on the non-encrypted JSON field read path, reducing per-request allocations for records with JSON fields.

### Security

- Each key generation derives an independent AES-256 key via domain-separated HKDF (`zigbase-field-encryption-v<n>`), so generations never share key material; generation 1 keeps the original domain for backward compatibility. Reads remain strict and fail-closed: a value whose envelope version has no configured key (unknown/missing generation), a wrong key, or a tampered/malformed value never yields plaintext. `rewrap` is fail-closed too — a cell it cannot decrypt aborts the run with the offending row reported and that collection's transaction rolled back, so no data is lost. Rotation keys come only from the environment and are never persisted or logged.
- **Startup now fails closed for runtime-created encrypted fields.** A server with an `.encrypted` field added at runtime (via the collections API while a key was set) would previously start on a later restart *without* `ZIGBASE_FIELD_KEY`. Startup now scans the live database schema after provisioning and refuses to start (`error.FieldKeyRequired`) if any DB-resident collection declares an encrypted field while no key is configured — matching the existing comptime guard. (The value layer already failed closed on read/write, so plaintext never leaked; this just turns a silently half-broken server into a loud refusal.)
- Outstanding session tokens can now be invalidated server-side before they expire. A
  bumped token epoch causes verification to reject every prior `.auth` token for that
  principal (fail closed — the epoch is trusted only after signature verification). Use it
  on password change, suspected compromise, or an explicit "sign out of all devices".
- With `.session_store = .table`, a revoked or expired per-device session is rejected at
  verify time (fail closed), and per-session `revoke` is authorized to the owning user or a
  superuser (a user cannot revoke another user's session).
- Field encryption uses an authenticated AES-256-GCM envelope (`v1:` + base64url(nonce‖ciphertext‖tag)) with a fresh per-write nonce, sharing one audited primitive with OAuth-secret encryption via domain-separated key derivation. The key comes only from `ZIGBASE_FIELD_KEY` (HKDF-derived, never persisted or logged); the server refuses to start if an `.encrypted` field is declared without it. Reads are strict and fail-closed: a non-envelope (legacy plaintext), wrong key, or tampered value never yields plaintext.

### Internal

- Remove the deferred legacy `app`/`arena` fields from `Req(Input)` in `route_types.zig`
  (Theme A cleanup: examples/blog and examples/golfsim both already read `req.ctx.arena` /
  `req.ctx.app`; the fields were never needed and the migration comment is now moot).
- Update the stale `AuthApi` doc comment in `ctx.zig` that called `refresh`, `rotate`,
  `listActiveSessions`, and `revoke` "deferred" — all four were shipped in PRs #111/#112
  (session management, Variant B); the comment now documents the full surface including
  the `session_store = .table` requirement for per-device verbs.

## [0.6.0] - 2026-06-23

### Features

- **Auth-aware `Data.create`** — `Data.create` on an **auth** collection now runs the same credential transforms as the HTTP records handler (generates the per-record `tokenKey`, forces `verified=false`, hashes `password` when supplied), so a programmatically-created record works with `zigbase.auth.issueSession` / `mintLinkToken` immediately. `password` is **optional**, enabling passwordless (magic-link) sign-up to provision an account without hand-writing credential columns. Non-auth collections are unaffected; the lower-level engine `records.create` still does a raw insert for imports/migrations.
- `magic_link` and `otp` auth methods now honour `auto_create: true` — when an unknown identity calls `initiate`, a passwordless account is provisioned automatically (email set from the identity, `verified = false`) and the link or code is sent as usual. Enables "sign up or sign in" in one step. Accounts are created with `verified = false`; pair with `require_verified` only when a verification flow is in place.
- **`CommandMailer` (local-command / sendmail mailer)** — a built-in mailer that pipes the serialized RFC822 message to a local MTA's stdin (e.g. `sendmail -t -i` or `msmtp -t`) and treats exit 0 as success. The standard "delegate delivery to a local relay, hold no SMTP credentials in the app" setup. Selected via the new `ZIGBASE_SENDMAIL_COMMAND` env var (whitespace-split into argv; `From:` from `ZIGBASE_SMTP_FROM`), which takes precedence over SMTP in `DefaultMailerPlugin`. Re-exported as `zigbase.CommandMailer`.
- **Comptime `.indexes` on collection literals** — a `zigbase.App(.{ .collections = … })` collection may now declare `.indexes = .{ .{ .name, .fields, .unique?, .collation?, .where? }, … }`, lowered into the provisioned schema and emitted as `CREATE INDEX` DDL (case-insensitive via `.collation = .nocase`; conditional-unique via `.where`). Index `.fields` reference fields by their declared name.
- **`ZIGBASE_PUBLIC_URL` → clickable magic-link emails** — set `public_url` (env `ZIGBASE_PUBLIC_URL`) and the built-in `magic_link` method emails an absolute link to its consume endpoint (which sets the session cookie and redirects) instead of a bare token. Unset preserves the previous raw-token email. Lets a stock binary offer real magic-link login by configuration alone.
- Comptime OAuth2 providers: declare `.auth.oauth2 = .{ .enabled = true, .providers = .{ .{ .name = "google", .redirectUrls = .{…} } } }` on an auth collection in `.collections`. The runtime `clientId`/`clientSecret` are sourced from `ZIGBASE_OAUTH_<NAME>_CLIENT_ID` / `ZIGBASE_OAUTH_<NAME>_CLIENT_SECRET` at provisioning time and the secret is encrypted (AES-256-GCM) before it is persisted — secrets never live in the binary. (Applied on first creation only; rotate via the admin API.)
- **Dev-only injectable test clock (`ZIGBASE_FAKE_NOW`)** — freeze the framework's "now" to an ISO-8601 UTC instant (e.g. `2029-03-07T16:00:00Z`) so time-boundary scenarios (token expiry, scheduling, challenge/cursor TTLs) are deterministic in e2e suites. Every framework-controlled timestamp routes through one clock seam (`src/clock.zig`) that honors the override. **Gated off in production:** compiled in only on a `dev_clock` build (on in `Debug`, off in any release build / shipped binary), so a production binary never reads the env var and time can never be frozen. Scope and the production gate are documented in [Known limitations → Testing](./known-limitations). Closes #58.
- `golfsim` example: `require_verified = true` on the `users` auth collection — guests must verify their email before a session is minted (booking/payments justification).
- `golfsim` example: OTP passwordless login (`auto_create = false`) for existing verified accounts; first-time onboarding remains password signup + email verification.
- `golfsim` example: comptime indexes — `NOCASE` unique on `users.email` (prevents case-variant duplicate accounts) and a partial composite index on `bookings(listing, starts_at) WHERE status != 'cancelled'` (backs the double-booking overlap check and availability route).
- `golfsim` example: OAuth2 "Sign in with Google" via comptime `.auth.oauth2`; client credentials sourced from `ZIGBASE_OAUTH_GOOGLE_CLIENT_ID` / `ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET` at provision time; Google-verified accounts are created `verified=true`.
- `golfsim` frontend: multi-step `Auth` component covering password sign-in, OTP initiate/complete, signup, email-verification, and Google OAuth2 flows.
- Blog example: adds built-in `magic_link` auth on `users` (passwordless login via
  emailed link, `auto_create = true`, 1 h TTL, server-redirects to `/`).
- Blog example: `NOCASE` unique comptime index on `users.email` via `.indexes = .{...}`
  — prevents case-variant duplicate accounts.
- `examples/plugins` showcases the full advanced auth surface: `authors` auth collection with WebAuthn (passkeys) + a custom `ApiTokenMethod` plugin; `commenters` auth collection with magic-link (`auto_create=true`); `onAuth` hook logging all three methods; comptime `NOCASE` collation index on `authors.contact_email`; frontend magic-link comment flow; `beforeCreate` hook auto-populating `commenter` from session.
- **Comptime index collation + partial predicates** — `schema.Index` gains `collation` (`.binary` default / `.nocase`, applied per indexed column) and an optional `where: ?[]const u8` partial-index predicate. Case-insensitive indexes (`CREATE INDEX ... ("email" COLLATE NOCASE)`) and conditional-unique indexes (`... WHERE deleted_at IS NULL`) are now expressible in the comptime `.collections` schema and emitted in the generated `CREATE INDEX` DDL, instead of requiring an out-of-band raw-SQL bootstrap. Defaults preserve existing DDL and JSON round-trip behavior.
- **`mintLinkToken` opaque bound payload** — `zigbase.auth.mintLinkToken` takes a trailing `opts: MintOptions` arg whose `payload` (default `""`) binds a small opaque string into the single-use token's signed `pl` claim, returned by `verifyLinkToken` as `claims.pl`. Lets a magic-link flow carry tamper-proof bound state (e.g. a post-login redirect target) in the one token instead of an unsigned `&next=` URL param. Signed, not encrypted — readable-but-tamper-proof; keep it small. Existing call sites add `.{}`.
- **`GET .../auth/magic_link/consume` — browser-friendly email-link login** — `GET /api/collections/:col/auth/magic_link/consume?token=…&redirect=/app` verifies and consumes the single-use link token (same replay guard as `complete`), mints the session through the shared `issueSession` seam (so `onAuth(.magic_link)` fires and the `zb_auth`/`zb_csrf` cookies are set), honors the `require_verified` gate, and `302`s to the redirect target. Two new per-method `magic_link` options shape the redirect: `redirect_default` (fallback path when `?redirect=` is absent or rejected; defaults to `/`) and `redirect_allow` (allow-list of exact paths or `/`-suffixed prefixes; an empty list permits any safe relative path).

### Fixes

- **Comptime `.indexes` is no longer silently ignored** — the documented `.indexes` key on collection literals was never lowered by the provisioner; it is now applied.
- Corrected false claim in `examples/plugins` migration 0002 comment: provisioned collection columns are human-named (field.name), not id-named. Raw migrations targeting migration-owned tables remain valid; the rationale is now accurate.

### Changed

- **Documented the CSRF double-submit contract for cookie sessions** — the API reference now spells out that cookie-session clients must echo the readable `zb_csrf` cookie in the `X-CSRF-Token` header on unsafe methods (`POST`/`PUT`/`PATCH`/`DELETE`); `GET`/`HEAD`/`OPTIONS` are exempt. A failed CSRF check makes the request anonymous, so the response status follows the collection's access rules — `403` on a create denial, `404` on an update/delete denial against a protected record (existence-hiding) — not a flat `403`. Documentation only; no behavior change.

### Performance

- Trim unused subsystems from the vendored SQLite amalgamation (`OMIT_UTF16`, `OMIT_DECLTYPE`, `OMIT_DEPRECATED`, `OMIT_PROGRESS_CALLBACK`, `OMIT_TRACE`, `OMIT_SHARED_CACHE`, `DEFAULT_MEMSTATUS=0`). The framework uses only SQLite's UTF-8 prepare/step/bind/column/exec surface, so this is a pure build-cost/size win — a smaller shipped binary and ~10% faster SQLite C compile — with no behavior change. FTS5 is intentionally retained.

### Security

- **Server-side open-redirect guard on magic_link consume** — the `?redirect=` target is validated server-side so consumers never re-implement the guard: only same-origin relative paths are honored. Off-origin, protocol-relative (`//host`), scheme, CRLF/control-byte, backslash, `.`/`..` path-traversal segments, and still-encoded `%2e`/`%2f`/`%5c` payloads are all rejected and fall back to `redirect_default`.

### Internal

- **Changelog-fragments workflow** — changes now add a `changelog.d/<slug>.md` fragment (with one or more `### <Section>` headings) instead of editing `CHANGELOG.md`, so parallel PRs never conflict on the shared changelog. `scripts/assemble-changelog.sh` aggregates the fragments per section into a new version block in `CHANGELOG.md` (and its `site/` mirror) at release time (run from `scripts/release.sh`) and deletes them. See [`changelog.d/README.md`](changelog.d/README.md).
- Corrected the "provisioned columns are named by a stable field id" claim in `CLAUDE.md` and `docs/framework.md`: physical SQLite columns use the human field name; the stable field id only matches columns across additive rebuilds.
- Blog example frontend: new magic-link login form in `Editor.tsx` (email → initiate
  → "Check your email" state), cookie-session detection via `getMe()` on mount, and an
  `AuthStatus` nav island for logged-in display after consume redirect.
- Blog example README: document `ZIGBASE_PUBLIC_URL`, the fake `blog.test` URL, and
  the email index.
- Cache Zig's **local** cache dir (`ZIG_LOCAL_CACHE_DIR`) across CI runs, where the compiled SQLite object actually lives. The previous "global cache" step only persisted toolchain artifacts (compiler_rt/translate-c), so every CI run recompiled the SQLite amalgamation once per `zig build` invocation (~6×/run: main + each example + the unit job). All builds in a job now share one cached local dir, eliminating those recompiles on warm cache. Corrected the misleading comment on the global-cache step.
- Use deliberately weak argon2id parameters in **test builds only** (keyed on `builtin.is_test`). The unit suite hashes/verifies passwords across ~700 tests; at production cost (`interactive_2id`, 64 MiB) that KDF work alone was ~25 s of every `zig build test`. A warm `zig build test` now runs in ~6 s (was ~32 s). The shipped server binary and the Playwright browser suite (which drives the real binary) are unaffected and keep full-strength params.

## [0.5.0] - 2026-06-21

### Removed

- **BREAKING: legacy OAuth2 endpoints removed** — `GET .../oauth2-providers`, `POST .../oauth2-init`, and `POST .../auth-with-oauth2` no longer exist. OAuth2 is now exclusively the contract method: `POST .../auth/oauth2/initiate`, `POST .../auth/oauth2/complete`, and `GET .../auth/oauth2/providers` (discovery).

### Added

- **OAuth2 as a first-class `AuthMethod`** — exclusively at the contract endpoints `POST /auth/oauth2/initiate`, `POST /auth/oauth2/complete`, and `GET /auth/oauth2/providers` (discovery); all paths share one implementation and the single `onAuth` session seam. See [docs/api.md](docs/api.md#oauth2) for request/response shapes.
- **Pluggable auth-method system** — the `AuthMethod` contract (`initiate`/`complete` + `AuthCtx` blessed helpers + `Resolution`) lets the framework own session issuance while methods plug in verification logic. Built-ins implement the same contract with no privileged path.
- **Per-collection `.auth.methods` config** — enable and configure built-in methods per auth collection: `password` (backward-compat default when `.methods` is absent), `magic_link` (TTL, auto-create flag), `otp` (code length, TTL), `webauthn` (rp_id, rp_name, origin, credentials_collection). Each method has a `rate_limit` knob (`.default` | `.off` | `.{ .custom = .{ .max, .window_s } }`).
- **App-level `.auth_methods`** — register custom `AuthMethod` plugin TYPES at comptime (same pattern as `.storage`/`.mailer`); a type missing `create`/`method`/`deinit` is a compile error.
- **Auto-mounted auth endpoints** — for every enabled method, the framework auto-mounts `POST /api/collections/:col/auth/:method/initiate` and `.../complete`; the dispatch enforces enablement (404 for disabled/unknown methods) and default rate-limits.
- **`magic_link` built-in** — enumeration-safe `initiate` (always 204), single-use link token emailed via the configured mailer, `complete` verifies+consumes and mints the session.
- **`otp` built-in** — enumeration-safe `initiate` emails a 6-digit code stored in the `ChallengeStore`, `complete` verifies the code.
- **`webauthn` built-in** — passkey login via the two-phase contract (initiate returns `PublicKeyCredentialRequestOptions`; complete verifies the signed assertion). Passkey registration via two authed endpoints (`register/begin` / `register/finish`). ES256 (P-256, COSE -7) and Ed25519 (COSE -8) supported; attestation `fmt:"none"` (v1); signCount clone detection (fail-closed); credentials stored in `_webauthnCredentials`.
- **`ChallengeStore`** (`_authChallenges`) — TTL'd, GC'd single-use server-side challenge storage used by `otp` and `webauthn`, and accessible to custom plugins via `AuthCtx.challengeStore()`.
- **`onAuth` method tagging extended** — `AuthEvent.method` is an enum: `.password`, `.oauth2`, `.magic_link`, `.otp`, `.webauthn`, or `.custom` for custom plugins.
- **RPC client generation for auth endpoints** — the generated TypeScript client exposes non-password auth-method endpoints under an `auth` surface (initiate/complete stubs, currently untyped).
- **`zigbase.auth` consumer surface for custom auth flows** — `issueSession` (and `RouteEvent.issueSession`), single-use magic-link tokens (`mintLinkToken` / `verifyLinkToken` / `consumeLinkToken`), `deliverAuthMail`, and `rateLimit`. All session minting now funnels through one seam that always fires `onAuth`.

### Security

- **OAuth2 server-side CSRF `state` is now ON by default** (`ZIGBASE_OAUTH_STATE_SERVER` defaults to `true`). The `initiate` endpoint issues a `state` value and `complete` requires and consumes it before contacting the provider. **Behavior change:** OAuth2 clients must use the `initiate`→`complete` flow; bare `complete` calls without a valid `state` are rejected with `400`. Set `ZIGBASE_OAUTH_STATE_SERVER=false` to restore the previous client-driven mode.
- **New `require_verified` per-collection auth option** (default `false`). When `true`, any login attempt for an unverified record is rejected with `403`. This gate applies to **all** methods — including WebAuthn/passkey and OAuth2 accounts whose provider email was unverified (those are created `verified=false`). Enabling it will lock out such users until they complete email verification.
- **OAuth2 no longer claims unverified provider emails** — when a provider does not mark the email as verified, the new account is created with `verified=false` and the `email` field is left unpopulated. This prevents email-squatting via an OAuth2 provider that does not verify addresses.
- **WebAuthn credential binding** — a passkey is now bound to the collection it was registered on; presenting it on a different collection returns `401`.
- **WebAuthn `require_uv` option** (default `false`). When `true`, the server rejects assertions that do not set the user-verification bit (`UV=1`), requiring biometrics or PIN at the authenticator.
- **WebAuthn COSE key curve validation** — ES256 credentials must use the P-256 curve; EdDSA credentials must use Ed25519. A mismatched algorithm/curve is rejected.

### Performance

- **Auth I/O off the write lock.** `otp` and `magic_link` release the DB connection before the SMTP send. WebAuthn signature verification runs before acquiring the write lock (only the signCount update and challenge consume hold it). `oauth2Providers` uses a reader connection. The authenticated-request fast path no longer does a redundant collection lookup. No auth method holds the single writer across blocking I/O or CPU-heavy verification.

### Changed

- **Auth methods now manage their own DB connections** — each method holds one connection across its work; OAuth2 `complete` releases the writer during the provider HTTP exchange (no write-throughput stall); password `complete` uses a reader (argon2 is read-only). Neither method blocks writes during I/O.
- **Session issuance (password, refresh, OAuth2) routes through a single
  `issueSession`+`emitAuth` seam** — custom routes can no longer mint a session that
  skips the `onAuth` hook.

## [0.4.1] - 2026-06-19

### Added

- **`zigbase --version`** (and the `version` subcommand) prints build provenance —
  the `build.zig.zon` version, the git commit, the build mode, the target triple,
  and the Zig version. Implemented at the framework level, so every binary built
  on ZigBase (including the examples and downstream apps) inherits it.

### Changed

- **Prebuilt server binaries are now stripped** — release builds drop debug
  symbols, cutting each `@zigbase/server-<platform>` package and GitHub-release
  tarball from ~24 MiB to ~7 MiB (about 73% smaller) with no API or behavior
  change. `npm install @zigbase/server` and `npx @zigbase/typegen` download
  much less.

### Added

- **Untyped route handlers in framework mode.** `.routes` now accepts the raw
  `fn(*RouteEvent) anyerror!http.Response` handler form alongside typed
  `Req(Input)`/`Output` handlers. An untyped handler owns its full response, so it can
  set/clear a session cookie, return a redirect (`307`), or serve a non-JSON
  content-type (e.g. `text/calendar`, an HTML OAuth handoff) — things the typed JSON
  thunk cannot express. Untyped routes carry no typed `Input`/`Output` and are excluded
  from the generated TypeScript `zb.rpc.*` client, so they never produce a client method
  that would mis-parse their response.
- **`text.pattern` is now enforced on record writes** via a pure-Zig, linear-time
  (DoS-safe) Thompson-NFA matcher (`src/regex.zig`). Matching is unanchored (substring);
  anchor with `^…$` for a full-string match. Supported syntax: literals, `.` (any codepoint
  except `\n`), anchors `^`/`$`, character classes `[…]`/`[^…]`/ranges, predefined classes
  `\d \D \w \W \s \S` (ASCII), escapes `\t \n \r \f \v` and `\`-escaped metacharacters,
  alternation `|`, groups `(…)`/`(?:…)`, and quantifiers `* + ? {m} {m,} {m,n}`. Patterns
  are validated when a collection is saved (a bad regex is a `400` field error), and at build
  time (`@compileError`) for comptime schema literals.
- **`date` field `min`/`max` are now enforced** on record writes, with date normalization
  (`src/datetime.zig`) so mixed formats (e.g. `2026-06-10 08:00:00` vs
  `2026-06-10T08:00:00Z`) compare correctly. Malformed or out-of-range date values are
  rejected with `400` (`validation_date`). Bounds are validated at collection-save time
  and at build time (`@compileError`) for comptime schema literals.

### Fixed

- **The HTTP status line now matches the response body for *every* status a handler
  returns, not a hand-picked subset.** `setZapStatus` previously mapped a short list of
  codes and sent everything else as `500`, so a custom route's `401` auth rejection, a
  `307` magic-link redirect, `410`, `502`, and similar went out with a `500` status line
  even though the JSON body still said e.g. `401`. The mapping now derives from
  `zap.http.StatusCode`'s named values, so any standard code zap defines is passed through
  and only genuinely-unknown codes fall back to `500`.

## [0.4.0] - 2026-06-13

This round makes ZigBase **safe-by-default**: a security audit's findings were fixed and
the access-rule and deployment defaults were hardened. **It contains breaking changes** —
read the migration notes below before upgrading. The full audit is in
[`docs/security-audit.md`](docs/security-audit.md).

### ⚠ Breaking changes

- **Access rules are now safe-by-default.** A blank rule — `null` **or** the empty string
  `""` — now means **Locked (superusers only)**. Previously `""` meant **allow-all (public)**
  while `null` meant locked; that inverted-from-intuition default was the single easiest way
  to ship a collection wide open. The **only** way to make a rule public is now the explicit
  sentinel **`"@public"`**, and ZigBase logs a prominent startup warning for every `@public`
  rule so a wide-open collection is never silent.
  - **How to migrate:** audit every collection's `list`/`view`/`create`/`update`/`delete`
    rules. Any rule that was `""` *intending* "anyone" must become `"@public"`. Any rule that
    was `""` merely as a placeholder is now correctly Locked (superuser-only) — no change
    needed unless you relied on it being open. The admin UI rule editor is now a three-state
    selector (**Locked / Expression / Public**) and confirms before opening a rule to the public.
- **Secure-by-default deployment.**
  - **Bind defaults to `127.0.0.1:8090`** (loopback); was `0.0.0.0`. Expose all interfaces
    explicitly with `--http-host 0.0.0.0` (`ZIGBASE_HTTP_HOST`), behind a firewall / reverse proxy.
  - **`ZIGBASE_JWT_SECRET` is auto-generated and persisted** under the data dir on first run
    when unset. The shared `dev-insecure-secret-change-me` default is gone, and a provided
    secret shorter than 32 bytes is refused at startup.
  - **Auth cookies are `Secure` (HTTPS-only) by default.** For plain-HTTP local dev pass
    `--insecure-cookies` (`ZIGBASE_COOKIE_SECURE=false`).
  - **An empty `ZIGBASE_REALTIME_ORIGINS` now denies cross-origin browser WebSocket upgrades.**
    Same-origin upgrades (the embedded admin UI and any frontend served from the same binary)
    are always allowed; set `--realtime-origins` only for a *separate-origin* browser app.
  - **The rate limiter ignores `X-Forwarded-For` / `X-Real-IP` unless `--trust-proxy`**
    (`ZIGBASE_TRUST_PROXY=true`) is set. Direct exposure is now safe by default; enable
    `--trust-proxy` only behind a trusted reverse proxy.
- **`perPage` on record list queries is clamped to 500.**

### Security

- **SMTP/RFC5322 header injection** fixed — CR/LF/NUL rejected in mail `to`/`subject`/`from`
  and in the SMTP command path.
- **`email`-field validation** — rejects control characters and obviously-malformed addresses.
- **Realtime delete authorization** — delete events are authorized against a pre-delete
  snapshot, so owner-scoped collections no longer leak deleted record ids to other subscribers.
- **Realtime subscribe auth** — subscribing to a non-`@public` collection now requires auth.
- **Single-use tokens** — verification and password-reset tokens are now strictly single-use.
- **DoS caps** — a global WebSocket connection cap and a multipart part-count cap (plus the
  `perPage` clamp above).
- **Static symlink escapes refused** — served files are canonicalized and must resolve within
  the static root.
- **Optional server-side OAuth `state`** — an opt-in CSRF `state` store
  (`ZIGBASE_OAUTH_STATE_SERVER`); PKCE remains required in both modes.

### Added

- New CLI flags / env vars: `--http-host` (`ZIGBASE_HTTP_HOST`), `--insecure-cookies`
  (`ZIGBASE_COOKIE_SECURE`), `--trust-proxy` (`ZIGBASE_TRUST_PROXY`), `--realtime-origins`
  (`ZIGBASE_REALTIME_ORIGINS`), `ZIGBASE_OAUTH_STATE_SERVER`.
- Admin UI: a three-state API-rule editor (**Locked / Expression / Public**) that confirms
  before making a rule public.
- Framework: `zigbase.JobEvent` is re-exported at the top level (alongside `RecordEvent` /
  `RouteEvent` / `ErrorEvent`); comptime guards now give actionable compile errors for a
  mistyped `.migrations` value or a storage/mailer plugin missing a contract method.

### Fixed

- Large comptime `.collections` schemas (~5+ collections) no longer fail to build with
  "evaluation exceeded 1000 backwards branches" — the lowering raises its own eval-branch
  quota (a downstream `@setEvalBranchQuota` could not reach it).

## [0.3.0] - 2026-06-11

### Fixed
- **Multipart form values are no longer type-guessed by the HTTP layer.** The
  multipart parser was rewritten as a self-contained RFC 2046 parser over the
  raw request body. Previously, facil.io coerced form values at parse time
  (`45.00` → float, `"true"` → bool, `"123"` → int, `"007"` → `7` with the
  original text destroyed), so string-expecting fields failed validation and
  **fixed-mode number fields could not be set in a file-upload request at
  all**. Values now arrive byte-for-byte as sent, then a schema-aware coercion
  pass makes multipart input behave exactly like a well-formed JSON client.
- **Malformed multipart bodies return a clear `400` ("Invalid multipart
  body.")** instead of falling through to the JSON parser's misleading
  "Invalid JSON body."; out-of-memory during parsing propagates instead of
  masquerading as a 400.
- **Multipart parser edge cases:** boundary delimiters are validated per
  RFC 2046, so content containing a boundary-prefixed decoy can no longer
  truncate a value or smuggle extra form fields; flag-style (valueless)
  `Content-Disposition` parameters no longer drop the part; `name[]` bracket
  notation (PHP/jQuery convention) is normalized again; repeated `<field>-`
  removal keys delete all listed files; zero-byte file parts are skipped
  (matching the previous behavior); LWSP around `=` in the boundary parameter
  is tolerated.

### Added
- **Admin UI: a `scale` input for fixed-mode number fields** in the schema
  editor (shown when the mode dropdown is set to `fixed`). Together with the
  multipart fix above, fixed-point (money) fields are now fully usable from
  the admin UI — creatable in the editor and editable in the record drawer,
  file uploads included.

### Changed
- **`min`/`max` on text and number fields are now enforced** on record writes
  (previously stored but silently ignored). Violations return `400` with
  `validation_min` / `validation_max` on the offending field; text length is
  counted in unicode codepoints; number bounds are inclusive. **Note:**
  pre-existing records that violate their declared bounds will fail
  full-record re-saves (e.g. from the admin UI drawer) until corrected.
- **Multipart input semantics:** an empty value clears an optional non-text
  field to `null` (matching JSON `null`); a single occurrence of a multi-value
  field wraps into a one-element array (repeated keys already became arrays);
  repeated non-file keys are preserved as arrays instead of being dropped.

## [0.2.0] - 2026-06-10

### Fixed
- **Provisioning no longer leaks at shutdown:** `applySpecs` and `runMigrations`
  now wrap all internal allocations in a short-lived arena (backed by the
  caller's allocator), so intermediate allocations from `topoOrder`,
  `collections.create` / `ddl.quoteIdent`, `schema.indexesToJson`, and the
  `prov:` migration-name string are all freed before the call returns. The
  long-lived gpa accumulates nothing during startup provisioning.
- **Reserved field names in comptime `.collections` are rejected at compile
  time:** declaring a field whose name is reserved by the engine (`id`,
  `created`, `updated`, `email`, `username`, `passwordHash`, `tokenKey`,
  `verified`) now produces a clear `@compileError` at build time rather than an
  opaque validation failure at startup.

### Added
- **Static file serving:** root-path fallback with four comptime modes — runtime
  `--serve-static <dir>` flag (default), `.disabled`, comptime-hardcoded `.dir`, or
  assets fully `.embedded` in the binary via the new `embedStaticDir` build helper
  in `build.zig`. Embedded mode computes a CRC32 content `ETag` at build time and
  handles `If-None-Match`/304 itself. Dir mode (`--serve-static` or comptime `.dir`)
  delegates caching to facil.io's `sendFile` (`ETag`, `Last-Modified`,
  `Cache-Control: max-age=3600`, 304). All modes add `X-Content-Type-Options: nosniff`
  and lexical traversal protection (`..`, backslash, NUL). Static misses return
  plain-text 404; `/api/*` misses keep the JSON envelope.
- **Example frontends:** all three examples now ship an Astro + React-islands
  frontend (one per static mode: blog = runtime flag, golfsim = hardcoded dir,
  plugins = embedded). Blog and golfsim also gain comptime `.collections` schemas so
  the examples provision themselves at startup.

## [0.1.0] - 2026-06-10

First public release: a single-binary, PocketBase-inspired (not API-compatible)
backend-as-a-service in Zig 0.16, plus an embeddable Zig framework.

### Added
- **Collections & schema engine** with migrations and a `migrate` CLI command.
- **Records CRUD** with a typed query API: `filter` (comparison + `&&`/`||` + relation-path traversal + `@request.*` macros), `sort`, `expand`, and pagination.
- **Per-collection API access rules** (list/view/create/update/delete): superuser-only, public, or filter-expression.
- **Authentication** — argon2id password hashing, JWT sessions over an httpOnly cookie with double-submit CSRF (and bearer tokens), and a `superuser create` CLI command.
- **OAuth2** — client-driven PKCE with Google / GitHub / Microsoft / Discord presets; AES-GCM-encrypted client secrets at rest.
- **Realtime** over WebSocket — rule-filtered create/update/delete events, per-subscription filters.
- **File storage** — local-disk backend behind an S3-ready storage interface; protected files via short-lived tokens.
- **Embedded admin UI** at `/_/` — a no-build Preact SPA (collections, records, schema editor, realtime live-view, OAuth2 config).
- **Embeddable Zig framework** — extend ZigBase from your own Zig app via comptime configuration: record lifecycle hooks, custom HTTP routes (with `public`/`authed`/`superuser` gating), auth/file/lifecycle/error events, a cron/interval/reactive job scheduler with backoff-retry and a worker pool, and `app.submit` for ad-hoc background work. Events expose `writer()` / `reader()` RAII DB accessors. Misconfiguration (unknown config keys, typo'd hook phases) is a compile error.
- **Comptime schema definition** — declare collections in Zig via `App(.{ .collections = .{ ... } })`, provisioned at startup with **additive auto-migration** (creates missing collections, adds new fields, resolves relations by name); non-additive changes go through an explicit `.migrations` escape hatch.
- **Pluggable storage & mailer backends** — `App(.{ .storage = T, .mailer = T })` selects a comptime backend type; defaults are local-disk storage and a log/SMTP mailer.
- **SMTP mailer with TLS** — verification and password-reset email is delivered over SMTP (plaintext / STARTTLS / implicit TLS) when configured; logs the tokens in dev when SMTP is unset.
- **Auth rate limiting** — login, verification, and password-reset endpoints are rate limited (fixed window, configurable, disable-able), keyed on the proxy-supplied client IP with a per-identity fallback.
- **Comptime footprint levers** — `App(.{ .pools = .{ ... } })` tunes the warm-reader pool, job-worker pool, per-thread stack size, and SQLite page cache.
- **Performance** — a warm reader-connection pool and a blocking-mutex writer for higher write throughput under contention.
- **Apache-2.0 license** and cross-platform release binaries (Linux + macOS).

### Known limitations
See [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) — notably: SMTP must be configured for email delivery in production (tokens are logged otherwise); rate limiting trusts proxy-supplied client IPs; auto-migration is additive-only; and the scheduler is single-process.

[0.4.1]: https://github.com/valthon/zigbase/releases/tag/v0.4.1
[0.2.0]: https://github.com/valthon/zigbase/releases/tag/v0.2.0
[0.1.0]: https://github.com/valthon/zigbase/releases/tag/v0.1.0
