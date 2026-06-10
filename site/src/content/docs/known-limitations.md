---
title: Known limitations
description: Current caveats in ZigBase v0.1.0 — auth/email, framework hooks, schema migrations, fields, the scheduler, platform/UI gaps, and deferred work.
order: 3
group: reference
---

# Known limitations

ZigBase v0.1.0 is an early release. The gaps below are known and tracked for post-v0.1.

## Auth & email

- **Mailer requires SMTP configuration for production.** Verification and password-reset
  email is delivered when SMTP is configured (`ZIGBASE_SMTP_HOST` + friends; supports `none`
  / `starttls` / `implicit` TLS). **Without SMTP configured, those tokens are logged to the
  server** (the dev/CI default) rather than emailed — a real deployment must set SMTP. TLS
  verifies certificates by default; `ZIGBASE_SMTP_INSECURE` disables verification for
  self-signed relays only.
- **Rate limiting is keyed on the proxy-supplied client IP.** Login / verification /
  password-reset are rate limited, but the key comes from `X-Forwarded-For` / `X-Real-IP`, so
  it is only trustworthy **behind a reverse proxy that sets those headers**. On direct
  exposure (no proxy header) the limiter degrades to a per-submitted-identity key, which is
  still spoofable.

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

## Fields

- **Fixed-mode number fields can't be set in a multipart (file-upload) create/update.**
  The HTTP layer type-coerces multipart form values to numbers (`45.00` → float), while
  `fixed` mode requires **string** input — so a multipart request that carries a
  fixed-mode value fails with a 400 validation error. **Workaround:** create/update the
  record via JSON first, then attach files in a separate multipart `PATCH` that only
  carries the file field. Also note `fixed` mode requires a `scale` option (1..8) and is
  currently **not configurable from the admin UI** (use the API).

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

## Static file serving

- Static files are served without authentication — collection access rules do not apply
  to the static root; use file storage for access-controlled delivery.
- No `Range`/partial-content requests (no video seeking on large files served from the
  static root).
- No directory listings; directories resolve to `index.html` or 404.
- Path safety is lexical (`..`, backslashes, and NUL bytes are rejected); symlinks inside
  the static root are followed — do not point them outside the root.
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

These are tracked for post-v0.1. Contributions welcome.
