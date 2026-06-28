# Changelog

All notable changes to ZigBase are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
