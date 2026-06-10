# Known Limitations

ZigBase v0.1.0 is an early release. The gaps below are known and tracked for post-v0.1.

## Auth & email
- **No mailer — password-reset and email-verification tokens are written to the server log, not emailed.** A real deployment must read the token from the log (or wait for a mailer integration). This is the highest-impact gap for production auth.
- **No rate-limiting** on the login or password-reset endpoints.

## Framework / hooks
- **`before`-hook `ev.data` writes are not transactional** with the triggering record write. Before-hooks run *before* the database transaction begins and use the app allocator, so use them to read, validate, and mutate `ev.record` — not for atomic side-writes. (Mutate the record via `ev.arena`.)

## Scheduler
- **Single-process only** — jobs run in the serving process; there is no distributed coordination.
- **Cron is UTC, numeric-only** (no `JAN`/`MON` names), **minute-granularity**, and **ANDs day-of-month with day-of-week** (unlike Vixie cron, which ORs them when one is `*`).
- **Interval jobs fire measured from completion**, so a long-running interval job drifts from a fixed wall-clock cadence. Runs never overlap (single-flight).
- **`app.submit` runs ad-hoc tasks on a detached thread** that is not joined at shutdown; a task submitted right before shutdown may be cut off. (Cron jobs use the bounded, cleanly-joined pool.)

## Platform & UI
- **No Windows build** — Linux and macOS only (the embedded HTTP server depends on facil.io/zap).
- **Admin UI:** no logs or settings screens, and the record editor uses a plain textarea (no WYSIWYG rich-text editor) — both deferred.

## Other deferred work
- Image thumbnails / transforms; S3 and other storage backends; reader-connection pooling; `fields=` response projection; resumable/chunked uploads; realtime backfill/replay and per-event-guard load-tuning.

---
These are tracked for post-v0.1. Contributions welcome.
