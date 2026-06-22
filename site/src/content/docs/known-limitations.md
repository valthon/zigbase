---
title: Known limitations
description: Current caveats in ZigBase — auth/email, framework hooks, schema migrations, fields, the scheduler, platform/UI gaps, and deferred work.
order: 3
group: reference
---

# Known limitations

ZigBase is an early release. The gaps below are known and tracked for future releases.

## Auth & email

- **Mailer requires SMTP configuration for production.** Verification and password-reset
  email is delivered when SMTP is configured (`ZIGBASE_SMTP_HOST` + friends; supports `none`
  / `starttls` / `implicit` TLS). **Without SMTP configured, those tokens are logged to the
  server** (the dev/CI default) rather than emailed — a real deployment must set SMTP. TLS
  verifies certificates by default; `ZIGBASE_SMTP_INSECURE` disables verification for
  self-signed relays only.
- **Rate limiting keys on proxy headers only when `--trust-proxy` is set.** Login /
  verification / password-reset are rate limited. `X-Forwarded-For` / `X-Real-IP` are
  **ignored by default** (they are spoofable on direct exposure); set `--trust-proxy` /
  `ZIGBASE_TRUST_PROXY=true` only behind a trusted reverse proxy to honor them. Without a
  trusted proxy the limiter keys on the submitted identity/email (not header-spoofable). The
  limiter also fails open under memory pressure (it never becomes a self-DoS), so it is a
  throttle, not a hard guarantee.

## Framework / hooks

- **`before`-hook `ev.data` writes are not transactional** with the triggering record write.
  Before-hooks run *before* the database transaction begins and use the app allocator, so use
  them to read, validate, and mutate `ev.record` — not for atomic side-writes. (Mutate the
  record via `ev.arena`.)

## Schema / migrations

- **Comptime auto-migration is additive-only.** Startup provisioning of a comptime
  `.collections` schema creates missing collections and adds new fields, preserving data.
  **Non-additive changes (rename, drop, or type-change a field) are detected, logged, and
  skipped** — they require an explicit `.migrations` entry.

## Scheduler

- **Single-process only** — jobs run in the serving process; there is no distributed
  coordination.
- **Cron is UTC, numeric-only** (no `JAN`/`MON` names), **minute-granularity**, and **ANDs
  day-of-month with day-of-week** (unlike Vixie cron, which ORs them when one is `*`).
- **Interval jobs fire measured from completion**, so a long-running interval job drifts from
  a fixed wall-clock cadence. Runs never overlap (single-flight).
- **`app.submit` runs ad-hoc tasks on a detached thread** that is not joined at shutdown; a
  task submitted right before shutdown may be cut off. (Cron jobs use the bounded, cleanly
  joined pool.)

## Testing & determinism

- **The `ZIGBASE_FAKE_NOW` test clock governs the framework's clock, not SQLite's.** Setting
  `ZIGBASE_FAKE_NOW` to an ISO-8601 UTC instant (dev builds only) freezes every "now" the
  framework controls — token `iat`/`exp`, the scheduler's next-fire math, the auth rate-limiter
  wall clock, and the auth-challenge / keyset-cursor TTL and expiry checks — so time-boundary
  e2e scenarios are reproducible. **Out of scope:** a `datetime('now')`/`unixepoch('now')` a
  *consumer* writes in their own custom SQL, and SQLite column `DEFAULT` timestamps (e.g. a
  record's `created`/`updated`), still read the OS wall clock. The override does not replace
  SQLite's global clock; route consumer time-logic through the framework helpers if it must be
  frozen.
- **The test clock is impossible to enable on a production build.** It is compiled in only when
  the `dev_clock` build option is true (on in `Debug`, off in any release build; the release
  script ships it off). A production binary never reads `ZIGBASE_FAKE_NOW` — the override folds
  to a comptime no-op — so time can never be frozen in production.

## Static file serving

- Static files are served without authentication — collection access rules do not apply
  to the static root; use file storage for access-controlled delivery.
- No `Range`/partial-content requests (no video seeking on large files served from the
  static root).
- No directory listings; directories resolve to `index.html` or 404.
- Path safety is lexical (`..`, backslashes, and NUL bytes are rejected) **and**
  symlink-aware: a served file is canonicalized and refused if its real path escapes the
  configured static root, so a symlink inside the root pointing outside it is not followed
  out.
- No on-the-fly compression; pre-compress at the CDN or reverse proxy if needed.
- In **dir** mode (`--serve-static` or comptime `.dir`), caching is controlled by
  facil.io's `sendFile` (fixed `Cache-Control: max-age=3600`) — this value is not
  configurable yet.

## Platform & UI

- **No Windows build** — Linux and macOS only (the embedded HTTP server depends on
  facil.io/zap).
- **Admin UI:** no logs or settings screens, and the record editor uses a plain textarea (no
  WYSIWYG rich-text editor) — both deferred.

## Other deferred work

- Image thumbnails / transforms; an S3 (or other remote) storage backend — a pluggable
  `.storage` slot exists, but only the local-disk backend ships; `fields=` response
  projection; resumable/chunked uploads; realtime backfill/replay and per-event-guard
  load-tuning.

---

These are tracked for future releases. Contributions welcome.
