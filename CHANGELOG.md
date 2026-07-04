# Changelog

All notable changes to ZigBase are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.10.0] - 2026-07-04

### Breaking

- Auth configuration is now grouped under one comptime `App(.{ .auth = .{ … } })` key. The previously-scattered top-level auth keys moved under it:
  - `.auth = .{ .beforeRegister = fn, … }` (the flat lifecycle-hook group) → `.auth = .{ .hooks = .{ .beforeRegister = fn, … } }`
  - `.auth_methods = .{ … }` → `.auth = .{ .methods = .{ … } }` (both the bare-tuple and `.{ .builtins, .custom }` forms)
  - `.captcha = .{ .provider, .secret }` → `.auth = .{ .captcha = .{ … } }`
  - `.session_store = .epoch | .table` → `.auth = .{ .session = .{ .store = … } }`
  - `.session_gc_cron = "…"` → `.auth = .{ .session = .{ .gc_cron = "…" } }`
  Each old spelling is now a pointed `@compileError` naming its new location, so consumers get an actionable migration message rather than a silent no-op. Runtime auth knobs (`ZIGBASE_AUTH_TOKEN_TTL`, `ZIGBASE_OAUTH_STATE_*`, cookie security, `ZIGBASE_RATE_LIMIT_*`) intentionally remain env-configured and are **not** part of the `.auth` group.
- `beforeAuthSuccess` now fires on the legacy `POST …/auth-with-password` and `POST …/auth-refresh` routes — **including `_superusers`** (the admin SPA login). A hook that errors unconditionally will lock superusers out of the admin UI (fail closed, by design); fix the hook and rebuild.
- `events.AuthMethod` gained a `.refresh` variant; exhaustive `switch`es over the enum must add an arm (compile error).
- Custom-route surface: `http.Response.file_path` is now `Response.file` (`.file_path = p` → `.file = .{ .path = p }`). Plain-path delegation behavior is unchanged; the new optional `offset`/`len` window enables handler-planned partial responses.
- Postgres backend (`-Dpostgres` builds): the default `sslmode` for `postgres://` URLs is now **`verify-full`** (the server certificate chain and hostname are verified — see the TLS entry under Security). A server without TLS (e.g. a docker-compose dev database) now fails **at startup** with an error naming the one-parameter fix: append `?sslmode=disable` (plaintext) or `?sslmode=require` (encrypted, unverified) to `ZIGBASE_DB_URL`. Explicitly configured modes below `verify-full` keep working and log one startup warning.
- Side-effect auth successes are now uniform **204 No Content**: `confirm-verification` (was `{"verified":true}`), `confirm-password-reset` (was `{"success":true}`), `webauthn/register/finish` (was `{"registered":true}`). Treat any 2xx as success; `@zigbase/client` types updated to `Promise<void>`.
- The magic-link consume URL is now dash-case: `GET …/auth/magic-link/consume` (was `auth/magic_link/consume`). Hard cutover — links emailed by pre-upgrade servers 404 (tokens are short-lived). The method slug (`/auth/magic_link/initiate|complete`, `onAuth` tag) is unchanged.
- The built-in job kinds are now config-gated (embedded consumers): `ctx.webhook` requires `.webhooks = true`; `ctx.mail().enqueue` requires `.mail` (use `.mail = .{}` for defaults) or a `.mailer` plugin. Without the key the kind is not compiled in and enqueue fails loudly with a hint. Direct mailer delivery (verification/password-reset emails) is unaffected. The kind names `mail`/`webhook` remain reserved either way.
- Removed the legacy `.jobs = .{ .pool_size = N }` spelling; set `.pools = .{ .jobs = N }`. The old key is now a pointed compile error (N1).
- `RecordEvent.ctx` is now `RecordEvent.rctx` (`ctx` always means `*Ctx` in a hook signature). Mechanical migration: `ev.ctx.` → `ev.rctx.`.
- `RecordEvent.app` was removed — it put the UB footgun (`ev.app.allocator` vs `ev.arena`) one dot from every hook. Use the hook's `ctx.app`; allocate record data with `ev.arena`. (`JobEvent.app`/`ErrorEvent.app` are unchanged.)
- `RouteEvent` was deleted. It was never passed to a live route (handlers take `*Ctx`); it existed only in tests. Events carry data; `ctx` carries capabilities.
- `GET /api/collections` and `GET /api/settings` now return `{"items":[…]}` instead of a bare JSON array (superuser endpoints; admin SPA + typegen updated). `zigbase typegen --url` requires a server from this release.
- `GET /api/collections/:col/auth/oauth2/providers` returns `{"items":[…]}` (was `{"providers":[…]}`); `@zigbase/client`'s `listAuthProviders` types updated.
- `zigbase.Server` is now a generic `pub fn Server(comptime gates: Gates) type` instead of a concrete struct — the built-in route table is assembled per-app from `Gates` (R2-3). Framework consumers reach it exclusively through `App(cfg).runCli`/`serve`, which thread the new `gates` config automatically; only code that named `zigbase.Server` directly (bypassing `App`) needs an update, e.g. `server.Server(.{})` for the historical all-on table.
- Storage plugin vtable: `localPath(ctx, alloc, col, record_id, filename)` is now `fetch(ctx, io, alloc, col, record_id, filename)` — return a local filesystem path whose contents are the file, **materializing it locally if necessary**; `null` = the backend has no such object. Local-disk backends migrate mechanically (rename + the `io` parameter).
- `GET /api/senders` now returns `{"items":[…]}` instead of a bare JSON array (unified with the analytics endpoints' envelope).
- The `__features` realtime channel now emits the standard `{"type":"signal","topic":"__features"}` frame instead of the bespoke `{"type":"features.changed"}` frame.

### Features

- Admin UI: an **Email** view — manage verified sender identities (list / invite / delete), the suppression list (add / remove / filter by reason, incl. one-click-unsubscribe entries), and read-only bulk-send batch progress, with a read-only mail-policy strip. Backed by the existing mail APIs plus a new superuser `GET /api/mail/config` (booleans only, no secrets).
- Admin UI: a **Files** view — browse per-collection file fields with image previews, upload/replace files, and remove them, plus a read-only storage-backend strip (local disk vs S3). Backed by the existing records + file-serve APIs plus a new superuser `GET /api/files/config` (non-secret backend info only — never the S3 credentials).
- Admin UI: a **Logs & realtime** view — browse app analytics events with name/actor/since filters and cursor pagination, view an app-declared rollup's aggregated series, and a read-only realtime health strip (live connection count + caps). Backed by the existing analytics APIs plus a new superuser `GET /api/realtime/stats`. The Logs tab is capability-gated: it only appears when the app enables `.analytics` (the stock `zigbase serve` binary doesn't, so the tab is hidden there).
- Admin UI: a **Users** view for managing superusers and auth-collection users — list, search, create/edit/delete, admin password reset, and a read-only OAuth-providers panel. The admin SPA is now split into browser-native ES modules (no build step) and every asset is served with a CRC32 `ETag`.
- Self-service password change via `PATCH /api/collections/:col/records/:id`: non-superusers must include a verifying `oldPassword` — a non-oracle check (wrong/missing values, unknown records, and passwordless targets all return the login-identical `400 "Invalid credentials."` with argon2 timing padding), rate-limited under a new `"pwchange"` scope before any argon2 work runs. On success every other session for the record is invalidated (tokenKey rotation, plus `_sessions` purge in table mode) while a self-change keeps the calling device signed in via fresh `Set-Cookie` headers. The `beforePasswordChange`/`afterPasswordChange` lifecycle hooks now fire on this path too. `@zigbase/client` gains `collection(col).changePassword(id, oldPassword, newPassword)` (transparent re-auth in token mode).
- Official multi-arch Docker image, `ghcr.io/valthon/zigbase` — built from the existing static-musl release binaries (no in-image compilation), `distroless/static` base, non-root by default. The supported deployment path for Windows-hardware users, since ZigBase has no native Windows build. See `docs/docker.md`.
- `migrate-db` now fully supports circular relations (self-relations and mutual/N-node cycles) end-to-end, not just provisioning: cycle-edge foreign keys are omitted from the initial `CREATE TABLE` and added back as `DEFERRABLE INITIALLY IMMEDIATE` constraints (Postgres cannot create tables with circular inline `REFERENCES` in any order), and the load transaction defers those constraints to `COMMIT` (`SET CONSTRAINTS ALL DEFERRED` on Postgres, `PRAGMA defer_foreign_keys=ON` on SQLite) so rows load in any order regardless of reference direction. Previously this schema shape failed outright during provisioning; SQLite targets were always cycle-capable (inline FK DDL tolerates cycles) but are now verified round-trip end to end. A dataset with a genuinely dangling reference fails clearly at `COMMIT`, naming the affected collections, and rolls the whole load back.
- Bulk list sends: `ctx.mail().sendBulk(...)` fans one templated message out as per-recipient-rendered emails over the durable queue, with submit-time validation/dedup, per-recipient suppression checks, idempotent redelivery, and a durable send-report (`_mail_batches` / `_mail_batch_recipients`, readable as superuser via the records API) plus `batchStatus` / `cancelBatch`.
- Scheduled sends: `ctx.mail().deliverAt(msg, .{ .at | .delay_s })` returns a cancellable job id, `ctx.mail().cancel(id)` calls a pending send off, and `sendBulk` accepts `.at` — the documented drip-sequence primitives.
- One-click unsubscribe (RFC 8058): configure `.mail.unsubscribe_base_url` (or `ZIGBASE_UNSUBSCRIBE_BASE_URL`) and bulk mail automatically carries `List-Unsubscribe` / `List-Unsubscribe-Post` headers pointing at the new signed public `POST/GET /api/mail/unsubscribe` endpoint; one-click opt-outs are recorded as `unsubscribe` suppressions that block list mail only (transactional mail is unaffected).
- Per-queue rate throttling: durable queues accept `.rate = .{ .per_second = N }` — a token-bucket ceiling enforced at claim time (e.g. match SES's 14 msg/s).
- `ctx.mail()` warns when an HTML body exceeds ~100 KB (Gmail clipping threshold).
- Record-file downloads (`GET /api/files/:col/:rec/:name`) support HTTP Range and conditional requests: `206` with `Content-Range` for `bytes=a-b` / `bytes=a-` / `bytes=-n`, `Accept-Ranges: bytes`, a strong content-immutable `ETag` with `304` revalidation, `If-Range`, `416` for unsatisfiable ranges, and `HEAD` parity.
- Generic OIDC discovery for OAuth providers: set `.discoveryURL = "https://…/.well-known/openid-configuration"` on a provider (mutually exclusive with explicit endpoint URLs) and the endpoints are resolved once at startup — https-only, issuer-checked, and **fail-fast** (a failed discovery refuses to start). Covers Auth0/Okta/Keycloak/Entra-custom-tenant/Zitadel-class IdPs with one config line; scopes default to `openid email profile` with the standard OIDC claim mapping.
- `.migrations` accepts a bare tuple (`.migrations = .{ .{ .id = "...", .up = f } }`) like every other list-shaped config key; the typed-slice form still works (E1).
- New `-Dfts5` build flag (default **on**): lean custom builds can drop SQLite's FTS5 (~250-400 KB). With `-Dfts5=false`, `?search=` answers 400 and a `.searchable` SQLite schema refuses at startup. Default builds are unchanged; Postgres full-text search is independent of the flag.
- New comptime `.admin = .disabled` key: headless/embedded consumers can drop the admin SPA (dispatch + ~58 KiB embedded assets) from their binary. Default unchanged — the admin UI serves at `/_/`.
- `.auth.methods` (the app-level auth-method registry) gains an exact-set form: `.{ .builtins = .{ .password, .otp }, .custom = .{ MyMethod } }`. Deselected built-ins (WebAuthn's CBOR/COSE stack, magic-link, OAuth2, OTP) are excluded from the binary together with their routes. Absent key / bare-tuple form keep today's all-five behavior — non-breaking.
- Cross-instance custom-topic realtime on Postgres (#188): `ctx.realtime().signal(topic)` / `ctx.realtime().broadcast(topic, payload)` and the `__features` flag/experiment signal now fan out across every app instance sharing one Postgres database (best-effort, at-most-once, unordered), not just the emitting process. No app data ever rides the `LISTEN`/`NOTIFY` wire: signals carry only the topic name, and message broadcasts store the enveloped frame in a new `_rt_broadcasts` side table keyed by a random CSPRNG token (TTL-GC'd), NOTIFYing only the token — the receiving instance reads the frame back over its own connection and re-delivers it through the same per-subscriber authorization chokepoint. A forged or expired token finds no row and is dropped (fail closed). The `ctx.realtime()` public API is unchanged; on SQLite (single-process) behavior is byte-identical.
- Opt-in S3-compatible storage backend (`-Ds3` build flag; AWS S3, MinIO, Cloudflare R2), selected by configuration alone — set `ZIGBASE_S3_*` env vars on an `-Ds3` binary, no code change. Downloads are served through a local spool cache, so Range/ETag/tenancy behavior is byte-identical to local storage. A stock binary with `ZIGBASE_S3_BUCKET` set warns loudly and falls back to local storage. Startup runs a fail-fast HeadObject probe (DNS/TLS/SigV4/bucket/permissions verified before serving).
- `@zigbase/client` 0.3.0: full-text `search` + structured `vector` queries (`vectorSpec`) on list reads, with per-collection compile-time gating in the generated tiers.
- `@zigbase/client` 0.3.0: multi-tenant account scoping — `accountId` option, `client.withAccount(id)` scoped views (shared auth store), and `accounts.activate(id)`.
- `@zigbase/client` 0.3.0: per-record abilities — `getAbilities(id)` on the base and every generated collection service.
- `@zigbase/client` 0.3.0: analytics read APIs — `client.analytics.events(...)` and `client.analytics.rollup(name, ...)`.
- `@zigbase/client` 0.3.0: verified sender management — `client.senders.list/create/verify` (list requires ZigBase >= 0.10.0).
- `@zigbase/client` 0.3.0: realtime custom topics — `subscribeTopic`/`unsubscribeTopic` deliver `signal` and `message` frames (feature-change notifications are `subscribeTopic("__features", cb)`).
- Generated TS clients surface `searchable`/`tenant` schema metadata: typed `search`/`vector` options, per-collection sort unions (`sort: "-age" | [...]`), tenant fields omitted from `*Create`/`*Update`, and `accounts`/`analytics`/`senders`/`withAccount` on the generated client.
- Per-device session REST + SDK for `.auth.session.store = .table`: `GET /api/collections/:col/auth/sessions` (`{"items":[…]}`, newest first, `is_current` marked), `DELETE …/auth/sessions/:sid` (`204`; non-owned/absent ids are an indistinguishable `404`), and `DELETE …/auth/sessions` ("log out everywhere", works in **both** session-store modes, clears the session cookies). In the default `.epoch` mode the per-device routes answer `404`. `@zigbase/client` gains `listSessions()`, `revokeSession(id)`, `revokeAllSessions()` and the `SessionInfo` type. The `sessions` auth-method slug is now reserved.
- SPA fallback routing (#183): a presence-only `.spa` marker file makes its static
  directory an SPA root — GET/HEAD misses at or below it serve that directory's
  `index.html` (200), so client-routed apps survive deep links and hard refreshes.
  Works for both `--serve-static`/`.dir` trees and embedded manifests; real files,
  `/api` (including via normalized/double-slash paths), admin, and custom routes
  always win. In **dir** mode the marker is
  resolved **live** against the filesystem on every miss — adding, removing, or
  editing a `.spa`/`index.html` takes effect on the next request, no restart needed;
  startup only fails fast (with a clear, path-naming error) when a `.spa`-marked
  directory has no `index.html`, and an unreadable subdirectory is skipped with a
  warning rather than aborting boot. **Embedded** manifests keep a startup-derived,
  comptime-static marker set (there's no live filesystem to go stale). The fallback
  shell is served `Cache-Control: no-cache` with a revalidation ETag so a redeploy
  never strands deep links on a stale cached shell, and a file literally named
  `.spa` denotes this marker (ASCII case-insensitive) rather than being served.
- Comptime `static_routes` for custom builds (#183): declare `match → serve`
  rewrites on `App(.{ .static_routes = &.{...} })` with minimal segment matching
  (`:name` one segment, `*` one-or-more rest, `**` zero-or-more rest; first match
  wins). Patterns and embedded serve targets are validated at compile time; dir
  targets at startup. A new `enable_spa_marker` key gates the marker (default: on
  without routes, off with routes).
- Realtime over Server-Sent Events (#188): `GET /api/realtime/sse` (EventSource-compatible — no SDK required) + `POST /api/realtime/sse/:clientId` uplink speaking the same verb grammar as WebSocket. Same frames, same per-record delivery authorization, same Origin policy, same shared connection cap. New `--sse-heartbeat-seconds` / `ZIGBASE_SSE_HEARTBEAT_SECONDS` knob for the `: ping` heartbeat interval.
- Tunable Cache-Control for static file serving: `App(.{ .static_cache_control = "…" })`
  sets a comptime default, and `--static-cache-control <value>` /
  `ZIGBASE_STATIC_CACHE_CONTROL` override it at runtime (flag wins over env, both win
  over the comptime default). Applies only to static serving (dir/embedded/
  `--serve-static`) — record-file downloads keep their authorization-derived
  Cache-Control unchanged. Unset (the default) is byte-identical to today's stock
  `max-age=3600`. The value must be non-empty, CR/LF-free, and at most 256 bytes;
  an invalid value fails startup with a clear error instead of silently clamping
  or ignoring it.
- Static file serving now supports HTTP Range: `bytes=X-` (video seek), `bytes=-n`, and overlong ranges return correct `206` responses, unsatisfiable ranges `416` (previously these fell through to a full `200` or worse), and embedded static assets gain single-range `206`. A ranged **dir**-mode request with a matching `If-Range` now resumes with `206` instead of restarting as a full `200`: zigbase neutralizes an inverted `If-Range` branch in the vendored facil.io that deleted the `Range` header on a match (RFC 9110 §13.1.5), so interrupted downloads resume instead of re-downloading from scratch. Owned record-file (`/api/files/…`) and embedded serving were already RFC-correct here. (#192)

### Fixes

- `onAuth` on `POST …/auth-refresh` now reports `.refresh` instead of the mislabeled `.password`.
- `migrate-db` onto a non-superuser Postgres target (the common case for managed Postgres like RDS/Cloud SQL) no longer silently corrupts the load: the best-effort `SET session_replication_role = replica` FK-suspension attempt, when rejected for lack of privilege, was leaving the load transaction itself in Postgres's aborted state — so *every* subsequent statement in the load failed, regardless of whether the schema had any cycles at all. The attempt is now wrapped in a `SAVEPOINT` so a rejected privilege check no longer poisons the load.
- `_suppressions` gained the `updated` column the records engine's base-column SELECT requires, so superusers can actually browse it via the records API (migration `0019_bulk_mail`).
- Record-file downloads no longer emit a duplicate `Cache-Control` header (the handler's per-collection value used to be joined on the wire by facil.io's global `max-age=3600`).
- Shipped-binary size: fixed a code-gen accident in the bundled regex engine (`Builder`
  was materialized as a ~3 MB all-zero `.rodata` template copied at runtime on every
  `compile`) — the default ReleaseSafe binary shrinks ~40%, from ~7.6 MB to ~4.6 MB,
  with identical behavior.
- `app.submit` tasks and memory-queue jobs are now drained and joined at shutdown (a task
  submitted before shutdown completes instead of being cut off), and `app.submit` works
  whenever the server is running — a configured scheduler is no longer required.
- Postgres SCRAM authentication now applies RFC 4013 SASLprep to passwords: soft hyphens are stripped and non-ASCII spaces map to space before PBKDF2, prohibited/bidi-invalid and non-UTF-8 passwords keep PostgreSQL's own use-verbatim parity, and a password that would require NFKC normalization fails loudly at connect with a message naming the fix (previously: verbatim bytes and a mysterious `password authentication failed`). Printable-ASCII passwords are byte-identical fast-path (zero allocation).
- Postgres backend (`-Dpostgres` builds): a `postgres://` URL whose host is a DNS name (e.g. `localhost`, `db.internal`) now resolves through the OS resolver (`/etc/hosts` + `resolv.conf`) instead of failing to connect — previously only IP-literal hosts (`127.0.0.1`, `::1`) worked, so `verify-full` against a hostname could never complete its handshake.
- The `App(.{…})` config-key table in docs/framework.md claimed to be exhaustive while omitting 9 keys (`captcha`, `tenancy`, `abilities`, `mail`, `analytics`, `static_routes`, `enable_spa_marker`, `onFeatureExposure`, `features`); it is now complete, states each key's binary-size contract ("unset ⇒ excluded/data-only/always"), and documents the config-plane assignment rule + laziness contract.
- `ZIGBASE_DB_URL` (the SQLite-vs-Postgres selector), `ZIGBASE_PUBLIC_URL` (magic-link URL base), and `ZIGBASE_SENDMAIL_COMMAND` are now documented in the README env table and `zigbase help` — they were previously undiscoverable.
- Field-encryption (`ZIGBASE_FIELD_KEY`, `ZIGBASE_FIELD_KEY_GENERATION`, `ZIGBASE_FIELD_KEY_V<n>`) env vars are now in the README env table (previously only in `zigbase help`). OAuth (`ZIGBASE_OAUTH_STATE_SERVER`/`_STATE_TTL`), rate-limit (`ZIGBASE_RATE_LIMIT_MAX`/`_WINDOW`), and SMTP (`ZIGBASE_SMTP_*`) env vars are now in `zigbase help` (previously only in the README).
- README documented the `ZIGBASE_OAUTH_STATE_SERVER` default backwards (`false`); the server-side OAuth state store has defaulted **on** since it shipped. The env table now matches the code (set `=false` to opt out).
- Outbound HTTP client (`http_client.zig`, shared by S3, webhooks, OAuth2, and CAPTCHA verification): a response DEFINED to carry no body (a `HEAD` response, any `1xx`, `204 No Content`, or `304 Not Modified`) was still read as if it might have one, using whatever `Content-Length` it happened to arrive with — or, absent that, "read until the connection closes." Real S3 servers don't close keep-alive connections, so every S3 `DELETE` (always `204`, no `Content-Length`) and every `HEAD` on an existing key blocked for ~30 seconds (an unrelated idle-connection timeout eventually unblocking it) before this was caught by the new live MinIO tests.
- `.analytics.rollups` in the `App` config could never compile — a job-wrapper signature mismatch made the option dead-on-arrival since it was introduced.
- The TypeScript code generator emitted an orphan `Expand` type key (breaking `tsc`) for relations that target a collection outside the generated set; it now emits `never` for those relations instead.
- `@zigbase/client` realtime: concurrent `subscribe`/`subscribeTopic` calls for the same topic while the socket is open no longer send duplicate subscribe frames — later callers join the pending ack instead.
- Embedded static assets now send a `Cache-Control` header (previously none — revalidation still works via the unchanged CRC32 ETag).
- `.gz` sidecar responses now carry `Vary: Accept-Encoding` (shared-cache correctness).

### Changed

- Stale docs corrected: Postgres backend status in configuration, README backend
  description, tenancy example harmonization.
- `Email` / `MailMessage` gained an additive `list_unsubscribe` field (default `null`; CRLF-checked like every header field) emitted as RFC 8058 headers by all backends (SMTP/Command/SES/Postmark).
- `durable.enqueue` now returns the generated job id, and the queue GC reaps `canceled` jobs (internal signature change, pre-1.0).
- `CaptureMailer` records `reply_to`/`list_unsubscribe` and gained `all()` / `countTo()` accessors.
- The release binary no longer ships the demo feature flags/experiment (`dark_mode`, `maintenance`, `onboarding_flow`) — they were Playwright fixtures riding in production. `GET /api/features` on a stock binary is now empty until you declare your own.
- `GET /api/analytics/events` adopts the house cursor pagination: `?cursor=` request param and `nextCursor`/`hasNext` response keys (additive; `limit` cap 200 unchanged).
- Built-in routes are now comptime-assembled from your `App(.{…})` config: analytics, senders, the inbound mail webhook, one-click unsubscribe, and `accounts/:id/activate` are registered (and compiled) only when `.analytics`, `.mail`, or `.tenancy` is configured. Previously these routes always existed and answered 404/fail-closed when unconfigured; now they 404 as unknown routes. The standalone `zigbase serve` binary opts into `.mail = .{}`, so its mail routes (verified senders, the inbound webhook, RFC 8058 unsubscribe) stay registered and behave exactly as before; only the still-unconfigured analytics and tenancy routes now 404 uniformly.
- The typed where-DSL `in` operator now compiles to the native `field in (…)` filter operator (requires ZigBase >= 0.9.0; against older servers it is a 400).
- Clients regenerated by this release require `@zigbase/client` >= 0.3.0 (enforced by a `CoreSupports_0_3` marker type with a self-explaining typecheck error).
- The docs site gained dedicated feature guides for the 0.9.0 features (PostgreSQL, tenancy,
  abilities, search, analytics, email, jobs & webhooks, realtime broadcast), a CAPTCHA
  recipe, a refreshed landing page, and a competitor comparison page.

### Performance

- Collection-metadata cache: `invalidate()` no longer allocates while holding the cache spinlock. Detached entries are threaded onto an intrusive list and their arenas/keys are freed only after the lock is released, removing an alloc-under-spinlock latency/contention hazard (and any re-entrant-allocator deadlock risk) on the DDL path.
- Memory-backend queues no longer spawn one detached OS thread (with a 1 MiB stack) per
  enqueued job: jobs run on a small fixed worker pool with a bounded ring. Overflow
  returns `error.QueueFull` instead of unbounded thread creation, so enqueue bursts can
  no longer exhaust threads or address space.
- Realtime delete fan-out: the per-subscriber authorization sandbox for delete events now
  creates only the tables it needs (2 statements) instead of running the full ~28-table
  migration suite once per subscriber per delete — removing the worst per-event fan-out
  cost on the shared HTTP threads.
- Collection metadata (the parsed schema consulted by every record API request and every
  realtime delivery) is now served from a versioned in-process cache invalidated on
  collection create/update/delete (SQLite backend; Postgres deployments keep direct reads
  so multi-instance DDL stays coherent) — removing a `_collections` SELECT plus a full
  schema-JSON parse per request and per realtime fan-out delivery.
- The embedded admin UI's assets now carry build-time `ETag`s and answer `If-None-Match`
  with `304 Not Modified`, so revisiting the admin no longer re-downloads the SPA bundle
  on every load.

### Security

- The SASLprep mapping/prohibited/bidi/NFKC-quick-check sets are vendored-generated range tables (`scripts/gen-saslprep-tables.py` over the frozen RFC 3454 appendices + Unicode 16.0.0 UCD extracts) — auditable binary-search tables, mechanical to bump.
- Postgres TLS supports real server-certificate verification: `sslmode=verify-ca` / `verify-full` are accepted (previously rejected at parse time), a new `sslrootcert=<path|system>` URL parameter selects the CA bundle (built once at startup, shared by all pooled connections, fail-fast on a missing/empty bundle), certificate validity is checked against real wall-clock time, and handshake failures surface actionable startup errors (untrusted chain, hostname mismatch, expired / not-yet-valid certificate, server refused TLS) that never include the connection URL.
- Realtime slow-consumer backpressure (issue #203): each WebSocket/SSE connection now has a per-connection outbound high-water-mark. A client that reads slowly or stalls without closing used to let the server buffer its outbound frames without bound (an OOM/DoS risk); once a connection's queued outbound frames exceed the bound it is now disconnected (the standard pub/sub choice — a clean reconnect + re-fetch, never a silent frame drop). Default `1024` frames; tune with `--realtime-outbound-hwm N` / `ZIGBASE_REALTIME_OUTBOUND_HWM` (`0` disables).
- Fixed an unauthenticated, remotely-triggerable heap double-free (and double connection-slot release) on the realtime WebSocket upgrade path: a malformed `Sec-WebSocket-Version` handshake drives facil.io's `bad_request` branch, which already invokes the connection's `on_close` teardown before returning failure — the adapter then tore the connection down a second time. In a release build this was a potential denial of service. The SSE upgrade path (new in 0.10.0) is hardened identically. Both transports now leave failure-path teardown solely to facil.io's `on_close`.
- Comptime custom routes (an app's `.routes` config) now resolve the active account exactly like the REST record/analytics/senders endpoints. Previously `dispatchCustom` never resolved tenancy: `ctx.track()` calls from a custom route stamped an empty account, and — more seriously — reads of tenant-owned collections made through a custom route were served **unscoped**, exposing cross-tenant data to any caller who could reach the route. Custom routes now resolve tenancy identically to the REST chokepoints. File serving (`GET /api/files/:col/:rec/:name`) had the same gap and is fixed the same way: it now resolves the active account before evaluating `viewRule`, so a file on a tenant-owned collection is no longer reachable cross-tenant by a caller who merely knows the collection/record/filename, and `@request.account.*`/cookie-activated rules now see the correct scope.

### Internal

- CI now enforces formatting: a `zig fmt --check src build.zig` gate in the `unit` job fails the build on any unformatted file, paired with a one-shot tree-wide `zig fmt` sweep so the tree starts clean.
- Scoped the `zig-local-*` build/test caches by branch (`github.ref_name` folded into both the `key:` and `restore-keys:` prefixes of every job) so one branch can no longer restore and reference another branch's cached objects — the cross-branch cache poisoning that surfaced a phantom symbol error in unrelated CI. The content-hash-keyed `zig-global-*` caches stay shared.
- Added a multi-threaded stress test for the collection-metadata cache: N threads hammer `lease()`/`invalidate()`/release concurrently, asserting no use-after-free, no leak (via the leak-checking test allocator), and correct post-invalidation reload.
- `dumpload.zig`'s collection-creation ordering is now a proper Kahn topological sort (`planCreateOrder`), with unit-tested, deterministic handling of relation cycles (self-relations and mutual/N-node cycles) that surfaces the in-cycle relation fields instead of just falling back to declaration order. Observable dump/load behavior for acyclic schemas (the common case) is unchanged; this lands the pure ordering primitive that Postgres deferred-FK cycle support (a follow-up task) builds on.
- Parallelized the Playwright/browser test suite (`tests/admin/`) with pytest-xdist (`-n auto`) in CI and reworked the harness fixtures to reuse a per-worker Chromium browser and a template superuser data dir, cutting the suite's serial wall time (~4:53) to ~18s on a 32-core box. No consumer-visible change.
- Fix a race in the admin browser test
  `test_shell.py::test_login_then_sidebar_lists_builtin_collections`: it counted
  the `nav-_superusers` sidebar link immediately after `login()`, but `login()`
  only waits for the static `nav-collections` link while the built-in-collection
  nav items render asynchronously just after — so the bare `count()` read 0 and
  the `browser` job flaked. It now waits for the selector before counting.
- Fix a ~2.4%-per-run flake in the Postgres realtime cross-instance tests
  (`realtime_pg_test.zig`): the delete-snapshot leak-canary asserted a bare
  owner value `u9` was absent from the NOTIFY payload, but the payload embeds a
  32-char random base36 token that coincidentally contains `u9` ~2.4% of runs.
  The canaries are now anchored to their JSON string quotes (`"u9"`, `"ssn"`),
  which a quote-less token/id can never forge, while still catching a real leak.
  The cross-instance waits also now loop over benign non-notification async
  messages (matching the production `pg_bridge` listener's tolerant contract)
  instead of failing on the first one.
- Corrected a false load-bearing comment in `static_files.zig` (facil.io does NOT
  percent-decode request paths; the `..` check is safe because encoded traversal stays a
  literal segment) and documented why `query/params.zig` keeps its own query parser
  (fio type-guesses values; zap returns them undecoded).
- Postgres backend: added `scripts/gen-saslprep-tables.py`, vendored RFC 3454 / Unicode 16.0.0 UCD source extracts (`vendor/unicode/`), and the generated `src/backend/postgres/saslprep_tables.zig` range tables (RFC 3454 B.1/C.1.2/C.2.x/C.3–C.9/D.1/D.2, plus UCD `NFKC_QC` and canonical-combining-class data) that a follow-up SASLprep normalization pass will consume. Not yet wired into any code path.
- A table↔`allowed`-tuple parity test (`tests/admin/test_docs_parity.py::test_config_key_table_matches_allowed_tuple`) guards the config-key table against future drift.
- Tightened the env-var help-parity test's text slice to end at `EXAMPLES:` instead of running to EOF — the old unbounded slice would false-pass a `ZIGBASE_*` name that only appeared in a later `std.log` message, not in the actual help text.
- Browser feature tests drive a dedicated `features-fixture` binary (`fixtures/features/`).
- Doc-drift guard: `tests/admin/test_docs_parity.py` fails CI when a `ZIGBASE_*` var referenced in `src/` is missing from the README table or the help text.
- CI now enforces the gating invariant: a minimal consumer build (`fixtures/minimal/`) is nm-scanned to prove deselected subsystems (WebAuthn, magic-link, OAuth2, analytics API, senders, mail webhook, webhook/mail job kinds, admin SPA) leave zero symbols (`scripts/check-gating.sh`), self-checked against a positive-control build (`fixtures/full/`) so a renamed/vacuous pattern also fails the check.
- Realtime delivery/verb authorization extracted from the WebSocket adapter into transport-neutral `hub.frameForDelivery`/`hub.authVerb`/`hub.subscribeCheck` (behavior-preserving; WS wire byte-identical) — groundwork for the SSE transport.
- SSE connection registry scaffolding (`realtime/sse.zig`): `SseConn` + pin/unref refcount, closed-flag lifecycle, and the per-delivery snapshot, with a strict `registry_mu`/`conn.mu` never-nested lock-ordering law and threaded-stress unit tests. Internal until the transport is wired end-to-end.
- SSE stream lifecycle wired onto the shared realtime upgrade path (`realtime/ws.zig` `handleUpgrade` now dispatches `sse` targets on `/api/realtime/sse`): `on_open` dups the handle, registers, and writes the connect frame; `on_close` runs the single authoritative reap; delivery snapshots under `conn.mu` and authorizes through the same `hub.frameForDelivery` chokepoint as WebSocket. Not yet a usable transport (no subscribe uplink until the next slice); Internal until then.
- New `s3` CI job: MinIO via `docker run` + gated live Zig tests + a raw-HTTP upload→Range→delete e2e (`tests/s3/`).
- Generalized the AWS SigV4 signer (`src/mail/sigv4.zig` → `src/aws/sigv4.zig`): parameterized method / canonical URI (S3 `UriEncode`) / signed-header list / service, SES signatures pinned byte-identical. Groundwork for the S3 storage backend; zero behavior change.
- Dual-transport (ws/sse) realtime e2e delivery matrix in the browser suite.
- Static Range support is a ~20-line request-header normalization shim + `HTTP_HVALUE_MAX_AGE` FIOBJ swap at `FIO_CALL_PRE_START` — facil.io keeps ALL static serving (directive 1); no owned static layer.

## [0.9.0] - 2026-06-30

A large release: a **PostgreSQL backend** alongside the default embedded SQLite, plus multi-tenancy, relationship-based authorization, full-text & vector search, product analytics, a transactional email subsystem, background job queues, outbound webhooks, CAPTCHA verification, and a realtime broadcast API.

### Breaking

- **Consumer migrations** (`.migrations`) now receive a `*zigbase.Migrator` instead of `(alloc, io, w)`. Change each `up` to `fn (m: *zigbase.Migrator) anyerror!void`: the writer is `m.db`, the arena `m.arena`, the request `std.Io` is `m.io`. `Migrator` carries the active SQL **dialect** so one migration runs on either backend — `m.execLowered(sql)` lowers SQLite-flavored DDL/seeds to the active backend (byte-identical on SQLite), `m.exec(sql)` runs raw backend-specific SQL, and `m.dialect.kind` / `m.rawFor(.postgres, …)` branch per backend. SQLite-only consumers just swap `w` → `m.db`.
- `ErrorPhase` gained a `.webhook` variant (additive). An `onError` handler that switches exhaustively over `ErrorPhase` must add a `.webhook` arm.

### Features

- **PostgreSQL backend (opt-in).** ZigBase can now run on PostgreSQL instead of the default embedded SQLite, selected by configuration alone — a `postgres://` `ZIGBASE_DB_URL` in a `-Dpostgres` build; application code and collection definitions are unchanged.
  - **Full feature parity:** record CRUD and the typed filter/sort/expand/search query engine, the access-rule + abilities + tenancy authorization stack, analytics rollups, the KV/TTL/rate-limit/feature-flag stores, field encryption + key rotation, the deterministic test-clock, and typed-client codegen all work identically on Postgres — verified against a live server in CI.
  - **Realtime across app instances:** a Postgres deployment can run multiple stateless app instances against one database, and record-change events fan out to subscribers on every instance via `LISTEN/NOTIFY`. The NOTIFY payload carries only an opaque token — never row data — so encrypted fields never leave the database in plaintext.
  - **Pure-Zig wire driver:** no libpq, C, or OpenSSL dependency (TLS via `std.crypto.tls.Client`, SCRAM-SHA-256 via `std.crypto`); the default SQLite build links zero new symbols. *Transport is encrypted but the server certificate is not yet verified in any sslmode (`verify-full` is a tracked follow-up) — use the Postgres backend over a trusted network path until then.*
  - **`migrate-db` CLI:** `zigbase migrate-db --from ./data.db --to "postgres://…"` copies an existing SQLite instance (schema **and** data) into a fresh Postgres database — provisions the equivalent schema, bulk-loads every table in one atomic transaction, preserves ids/timestamps/metadata, and carries encrypted-field envelopes byte-for-byte (no key needed). *FK suspension requires a superuser target; a managed non-superuser Postgres uses a lightly-tested topological-order fallback.*
  - **Vector search on Postgres** via pgvector, behind the same `-Dvector` flag and `?vector=` API as SQLite's sqlite-vec — one flag enables KNN on both backends.
  - **Admin backend badge:** the admin UI shows a "SQLite"/"Postgres" badge, sourced from a new `backend` field on `GET /api/health` (the kind only — never the connection string or credentials).
  - The default SQLite single-file deployment is unchanged. One safeguard: a stock (non-`-Dpostgres`) binary now reads `ZIGBASE_DB_URL` and logs a prominent warning if it is a `postgres://` URL, rather than silently writing to local SQLite.
- **Account-scoped multi-tenancy (#156).** `App(.{ .tenancy = .{ .enabled = true, .auth_collection = "users" } })` plus a collection's `.tenant_field = "account"` auto-scopes every read/write (and realtime delivery) of a tenant-owned collection to the request's active account via a bound `tenant_field = ?` predicate; create stamps the owning account and update rejects cross-tenant moves. The active account resolves from an `X-Account-Id` header or a signed `zb_account` cookie, verified against an active `_memberships` row (fail-closed). Adds built-in `_accounts`/`_memberships`/`_invitations` collections, a configurable role order (`viewer < editor < admin < owner`), `POST /api/accounts/:id/activate`, and the `@request.account.id`/`.role`/`.ids` rule macros. Superusers bypass; `zigbase.crossTenant(rctx)` is the explicit admin override. Apps with no `.tenancy` are byte-identical to before.
- **Relationship-based row abilities (#155).** Declare per-collection, per-action authorization by the principal's relationship to the row: `App(.{ .abilities = .{ .projects = .{ .update = .{ .relationship = .{ .via = "account", .min_role = .editor } } } } })` authorizes a row when the principal holds a membership (role ≥ `.min_role`) of the account it belongs to. Abilities compose into the existing guard stack, narrow the LIST endpoint, are fail-closed and comptime-validated, and `ctx.can(.action, "col", id)` + `GET …/records/:id/abilities` expose them to custom routes. Collections with no `.abilities` are byte-identical to before.
- **Search on the list endpoint (#157).**
  - **Full-text search** ships in the default build: mark a `text`/`editor` field `.searchable = true` and query with `?search=<terms>` — ranked by relevance, with `AND`/`OR`/`NOT`/prefix operators, provisioned automatically (SQLite FTS5; Postgres `tsvector` + GIN). Search composes with the full authorization stack and structured filters: `?search=X&filter=Y` returns the scoped intersection (never an unscoped query) and terms are always bound (no injection).
  - **Vector / nearest-neighbor search** behind an opt-in `-Dvector` flag: `?vector=<field>[:cosine|:l2]:<embedding>` KNN ordering composed into the same scoped query (sqlite-vec on SQLite, pgvector on Postgres). Not compiled into the default build.
- **Product analytics (#158).** `ctx.track("user.signup", .{ .plan = "pro" })` appends an immutable event — actor, tenant, and timestamp stamped server-side — to the new `_events` collection. Declarative rollups (`App(.{ .analytics = .{ .rollups = … } })`) incrementally aggregate events into summary tables on the scheduler. Tenant-scoped, fail-closed read API: `GET /api/analytics/events` (raw feed) and `GET /api/analytics/rollups/:name`. Usable standalone with no config.
- **Email subsystem (#154)** on `ctx.mail()`:
  - A safe multipart HTML + plain-text **template engine** (HTML-escaped by default, named partials + shared layout, no code evaluation).
  - First-class **SES** and **Postmark** HTTP providers behind the `Mailer` vtable (SMTP/Command unchanged), a per-message `From` override, and a `CaptureMailer` for asserting outbound mail in tests with no network.
  - **Verified per-account sender identities** and **bounce/complaint suppression** with an inbound provider webhook, all tenant-scoped. Enforcement (`.mail.require_verified_sender`, `.check_suppression`) defaults off, so an app that only calls the existing mailer is unaffected.
  - `ctx.mail().send(...)` / `.enqueue(...)` / `.deliverLater(...)`; `mail.Email` gains `html_body`/`reply_to`; the framework owns header-injection (CRLF) defense for every backend.
- **Background jobs & queues.** A generic multi-queue/worker/job engine: declare named `.queues` (memory or durable, prioritized, per-queue retry), `.workers` (bound to queues, strict-priority drain, concurrency), and a `.jobs` kind→handler registry, then enqueue from anywhere with `ctx.enqueue(.queue, .kind, payload)`. Durable queues persist to `_queue_jobs` with at-least-once delivery, crash-reclaim, and GC; memory queues need zero schema. Powers the built-in `"mail"` and `"webhook"` job kinds.
- **Outbound webhooks.** `ctx.webhook(url, payload, .{…})` delivers in the background on the queue engine with retry/backoff (honoring `Retry-After`, capped), optional HMAC-SHA256 signing, and a stable per-delivery `Idempotency-Key`; TLS certificate verification stays on.
- **Realtime broadcast API** for custom (non-record) channels, from a route or job: `ctx.realtime().signal(topic)` (a payload-less re-fetch trigger, the default for private state) and `.broadcast(topic, payload)` (delivered verbatim), over the same WebSocket subscribe protocol clients already use. New `App(.{ .realtime = .{ .canSubscribe = fn } })` gates custom-topic subscriptions; a custom topic can never reach a real collection's record channel.
- **CAPTCHA verification (#140).** `ctx.verifyCaptcha(provider, token)` for reCAPTCHA v2/v3, hCaptcha, and Cloudflare Turnstile, configured via `App(.{ .captcha = … })` (dev-bypass when the secret is empty).
- **Custom-route ergonomics.** Response builders (`ctx.json` / `jsonError` / `html` / `redirect` / `notFound`), deferred `ctx.setCookie` / `addHeader` (merged on both the success and error paths), lazy `ctx.query()`, `ctx.randomToken` / `randomHex`, and `ctx.subjectCookie` (an anonymous per-visitor id). A declarative route **guard pipeline**: `.auth` now also accepts a `path_secret` guard (constant-time shared-secret gate, bare-404 on mismatch) and `.rate_limit` adds per-route buckets keyed on the trust-proxy client IP. `http.Cookie` gains an optional `domain`.
- **Filter/rule grammar:** a new `in` set-membership operator (`field in ("a", "b")`, compiled to a bound `IN (?, …)`, empty set fail-closed) and the `@request.account.id` / `.role` / `.ids` macros that underpin tenancy and abilities.

### Changed

- A `.nocase` (case-insensitive) index now makes both **uniqueness and lookups** case-insensitive on SQLite. Previously a `.nocase` UNIQUE index treated `Bob@x.com`/`bob@x.com` as the same identity, but the lookup was case-sensitive — so a user registered as `Bob@x.com` could not log in as `bob@x.com`. Identity/email lookups and `=`/`!=`/`in` comparisons against a `.nocase` column are now case-insensitive, agreeing with the index (and matching the Postgres backend, which uses a `lower()` functional index). The built-in auth identity index remains case-sensitive — case-insensitive identity stays opt-in via a `.nocase` index.

### Security

- The shared one-time-code comparison was unified on the audited constant-time `crypto.timingSafeEql` primitive (the OTP auth method now uses it too).
- Webhook retry backoff (including a server-supplied `Retry-After`) is capped at the queue's maximum, so a hostile or misconfigured receiver cannot park a worker thread and starve the background pool.
- The new subsystems are fail-closed by design — tenant/ability/search scoping, the email verified-sender + suppression + CRLF-injection defenses, the realtime no-row-data-on-the-NOTIFY-wire guarantee, the `path_secret` constant-time gate, and per-route rate-limit IP keying are detailed under their features above.

### Internal

- CI now runs a `-Ddev-clock=false` production-gate test pass, so the tests asserting that `ZIGBASE_FAKE_NOW`/`ZIGBASE_FAKE_SEED`/test-capture are compiled out of production builds actually execute (they were previously skipped in the only CI test run).
- The e2e test harnesses now retry server startup on a port-bind race (fresh OS-assigned port + fast `ListenError` detection + cleanup between attempts), fixing an intermittent `ListenError` → "server did not become healthy" flake in the `ts-sdk`/`browser` jobs.
- New `policy.zig` authorization-composition layer and `src/sql/dialect.zig` SQL-dialect layer are the architectural seams the abilities/tenancy and the Postgres backend compose through.
- GitHub release descriptions now contain only the released version's changelog section (`scripts/extract-release-notes.sh`), not the entire `CHANGELOG.md`.

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
