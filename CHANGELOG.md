# Changelog

All notable changes to ZigBase are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
