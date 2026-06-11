---
title: Changelog
description: Release history for ZigBase, following Keep a Changelog and Semantic Versioning.
order: 4
group: reference
---

# Changelog

All notable changes to ZigBase are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-06-11

### Fixed

- **Multipart form values are no longer type-guessed by the HTTP layer.** The multipart
  parser was rewritten as a self-contained RFC 2046 parser over the raw request body.
  Previously the HTTP layer coerced form values at parse time (`45.00` → float, `"true"` →
  bool, `"007"` → `7` with the original text destroyed), so string-expecting fields failed
  validation and **fixed-mode number fields could not be set in a file-upload request at
  all**. Values now arrive byte-for-byte as sent, then a schema-aware coercion pass makes
  multipart input behave exactly like a well-formed JSON client.
- **Malformed multipart bodies return a clear `400`** ("Invalid multipart body.") instead
  of the JSON parser's misleading "Invalid JSON body.".
- **Multipart parser edge cases:** RFC 2046 boundary-delimiter validation (no truncation
  or part smuggling from boundary-prefixed content), flag-style `Content-Disposition`
  params, `name[]` bracket notation, repeated `<field>-` removal keys, zero-byte file
  parts, LWSP around `=` in the boundary parameter.

### Added

- **Admin UI: a `scale` input for fixed-mode number fields** in the schema editor.
  Together with the multipart fix, fixed-point (money) fields are now fully usable from
  the admin UI — creatable in the editor and editable in the record drawer, file uploads
  included.

### Changed

- **`min`/`max` on text and number fields are now enforced** on record writes
  (`validation_min` / `validation_max`; text length in unicode codepoints; bounds
  inclusive). Pre-existing records that violate their declared bounds will fail
  full-record re-saves until corrected. Date `min`/`max` and text `pattern` remain
  accepted-but-unenforced — see [Known limitations](./known-limitations).
- **Multipart input semantics:** an empty value clears an optional non-text field to
  `null`; a single occurrence of a multi-value field wraps into a one-element array;
  repeated non-file keys are preserved as arrays instead of being dropped.

## [0.2.0] - 2026-06-10

### Added

- **Static file serving:** root-path fallback with four comptime modes — runtime
  `--serve-static <dir>` flag (default), `.disabled`, comptime-hardcoded `.dir`, or assets
  fully `.embedded` in the binary via the new `embedStaticDir` build helper. Embedded mode
  computes a CRC32 content `ETag` at build time and handles `If-None-Match`/304 itself. Dir
  mode (`--serve-static` or comptime `.dir`) delegates caching to facil.io's `sendFile`
  (`ETag`, `Last-Modified`, `Cache-Control: max-age=3600`, 304). All modes add
  `X-Content-Type-Options: nosniff` and lexical traversal protection (`..`, backslash, NUL).
  Static misses return plain-text 404; `/api/*` misses keep the JSON envelope.
- **Example frontends:** all three examples now ship an Astro + React-islands frontend (one
  per static mode: blog = runtime flag, golfsim = hardcoded dir, plugins = embedded). Blog
  and golfsim also gain comptime `.collections` schemas so the examples provision themselves
  at startup.

## [0.1.0] — 2026-06-10

First public release: a single-binary, PocketBase-inspired (not API-compatible)
backend-as-a-service in Zig 0.16, plus an embeddable Zig framework.

### Added

- **Collections & schema engine** with migrations and a `migrate` CLI command.
- **Records CRUD** with a typed query API: `filter` (comparison + `&&`/`||` + relation-path
  traversal + `@request.*` macros), `sort`, `expand`, and pagination.
- **Per-collection API access rules** (list/view/create/update/delete): superuser-only,
  public, or filter-expression.
- **Authentication** — argon2id password hashing, JWT sessions over an httpOnly cookie with
  double-submit CSRF (and bearer tokens), and a `superuser create` CLI command.
- **OAuth2** — client-driven PKCE with Google / GitHub / Microsoft / Discord presets;
  AES-GCM-encrypted client secrets at rest.
- **Realtime** over WebSocket — rule-filtered create/update/delete events, per-subscription
  filters.
- **File storage** — local-disk backend behind an S3-ready storage interface; protected
  files via short-lived tokens.
- **Embedded admin UI** at `/_/` — a no-build Preact SPA (collections, records, schema
  editor, realtime live-view, OAuth2 config).
- **Embeddable Zig framework** — extend ZigBase from your own Zig app via comptime
  configuration: record lifecycle hooks, custom HTTP routes (with
  `public`/`authed`/`superuser` gating), auth/file/lifecycle/error events, a
  cron/interval/reactive job scheduler with backoff-retry and a worker pool, and `app.submit`
  for ad-hoc background work. Events expose `writer()` / `reader()` RAII DB accessors.
  Misconfiguration (unknown config keys, typo'd hook phases) is a compile error.
- **Comptime schema definition** — declare collections in Zig via `App(.{ .collections = .{
  ... } })`, provisioned at startup with **additive auto-migration** (creates missing
  collections, adds new fields, resolves relations by name); non-additive changes go through
  an explicit `.migrations` escape hatch.
- **Pluggable storage & mailer backends** — `App(.{ .storage = T, .mailer = T })` selects a
  comptime backend type; defaults are local-disk storage and a log/SMTP mailer.
- **SMTP mailer with TLS** — verification and password-reset email is delivered over SMTP
  (plaintext / STARTTLS / implicit TLS) when configured; logs the tokens in dev when SMTP is
  unset.
- **Auth rate limiting** — login, verification, and password-reset endpoints are rate limited
  (fixed window, configurable, disable-able), keyed on the proxy-supplied client IP with a
  per-identity fallback.
- **Comptime footprint levers** — `App(.{ .pools = .{ ... } })` tunes the warm-reader pool,
  job-worker pool, per-thread stack size, and SQLite page cache.
- **Performance** — a warm reader-connection pool and a blocking-mutex writer for higher
  write throughput under contention.
- **Apache-2.0 license** and cross-platform release binaries (Linux + macOS).

### Known limitations

See [Known limitations](./known-limitations) — notably: SMTP must be configured for email
delivery in production (tokens are logged otherwise); rate limiting trusts proxy-supplied
client IPs; auto-migration is additive-only; and the scheduler is single-process.

[0.2.0]: https://github.com/valthon/zigbase/releases/tag/v0.2.0
[0.1.0]: https://github.com/valthon/zigbase/releases/tag/v0.1.0
