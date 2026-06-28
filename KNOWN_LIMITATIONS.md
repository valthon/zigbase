# Known Limitations

ZigBase v0.7.1 is an early release. The gaps below are known and tracked for future releases.

## Auth & email
- **Per-device session list/revoke requires opt-in `.session_store = .table`.** The default `App(.{ .session_store = .epoch })` revokes per **principal** via the token epoch — `revokeAllSessions()` ("log out everywhere"), `refresh()`, `rotate()` — stateless, with zero extra DB work and unchanged token format. Opting into `App(.{ .session_store = .table })` adds a server-side `_sessions` store enabling `listActiveSessions()` and per-session `revoke(sessionId)` ("log out THIS device"), at the cost of **one extra read per authenticated request** (the documented trade-off). In `.epoch` mode the two per-device verbs return `error.SessionStoreNotEnabled`.
- **Mailer requires SMTP configuration for production.** Verification and password-reset email is delivered when SMTP is configured (`ZIGBASE_SMTP_HOST` + friends; supports `none` / `starttls` / `implicit` TLS). **Without SMTP configured, those tokens are logged to the server** (the dev/CI default) rather than emailed — a real deployment must set SMTP. TLS verifies certificates by default; `ZIGBASE_SMTP_INSECURE` disables verification for self-signed relays only.
- **Rate limiting keys on proxy headers only when `--trust-proxy` is set.** Login / verification / password-reset are rate limited. `X-Forwarded-For` / `X-Real-IP` are **ignored by default** (they are spoofable on direct exposure); set `--trust-proxy` / `ZIGBASE_TRUST_PROXY=true` only behind a trusted reverse proxy to honor them. Without a trusted proxy the limiter keys on the submitted identity/email (not header-spoofable). The limiter also fails open under memory pressure (it never becomes a self-DoS), so it is a throttle, not a hard guarantee.

## Framework / hooks
- **`before`-hook side-writes are atomic with the triggering write, but `ctx.records()` results are gpa-allocated.** On the HTTP create/update/delete path a `before`-hook runs *inside* the triggering write's transaction, so its `ctx.records()` side-writes commit atomically with the primary write and roll back together if the hook errors or the access rule denies (fail closed). The one caveat: values *returned* by `ctx.records()` (e.g. a `.get` result) are allocated from the app allocator, not `ev.arena` — copy with `ev.arena` before storing one into `ev.record`.

## Schema / migrations
- **Comptime auto-migration is additive-only.** Startup provisioning of a comptime `.collections` schema creates missing collections and adds new fields, preserving data. **Non-additive changes (rename, drop, or type-change a field) are detected, logged, and skipped** — they require an explicit `.migrations` entry.

## Scheduler
- **Single-process only** — jobs run in the serving process; there is no distributed coordination.
- **Cron is UTC, numeric-only** (no `JAN`/`MON` names), **minute-granularity**, and **ANDs day-of-month with day-of-week** (unlike Vixie cron, which ORs them when one is `*`).
- **Interval jobs fire measured from completion**, so a long-running interval job drifts from a fixed wall-clock cadence. Runs never overlap (single-flight).
- **`app.submit` runs ad-hoc tasks on a detached thread** that is not joined at shutdown; a task submitted right before shutdown may be cut off. (Cron jobs use the bounded, cleanly-joined pool.)
- **TTL record physical deletion is eventually consistent (~5 minutes), but expired rows are hidden from reads immediately.** Expired rows in a `.ttl_field` collection are **automatically excluded from every read** (list, get, relation expand — via the HTTP API and `ctx.records()`) by a read-time predicate that is ANDed with your filter, access rule, and keyset cursor, so no manual `expires_at > @now` filter is needed. Physical deletion is still handled by an internal GC job that runs once at startup and then **every 5 minutes** (the interval is not tunable), so an expired row may persist in the table until the next sweep — but it is never returned by a read in the meantime. A row whose ttl field is `null` never expires; a row with an unparseable ttl value is fail-safe (stays visible, never reaped).

## Testing & determinism
- **The `ZIGBASE_FAKE_NOW` test clock freezes the framework's clock AND consumer SQL `'now'`.** Setting `ZIGBASE_FAKE_NOW` to an ISO-8601 UTC instant (dev builds only) freezes every "now" the framework controls — token `iat`/`exp`, the scheduler's next-fire math, the auth rate-limiter wall clock, and the auth-challenge / keyset-cursor TTL and expiry checks. As of the consumer-SQL determinism work, it **also** freezes a consumer's own raw `datetime('now')` / `unixepoch('now')` / `strftime(…, 'now')` (and `date`/`time`/`julianday`, including their zero-argument implicit-`'now'` forms): those date/time builtins are shadowed on every reader and writer connection so they resolve to the frozen instant, while every other input (explicit datetimes, `'+1 day'` modifiers, the `strftime` format string) passes through to genuine SQLite. It **also** freezes the SQL keywords `CURRENT_TIMESTAMP` / `CURRENT_TIME` / `CURRENT_DATE` and column `DEFAULT CURRENT_TIMESTAMP` timestamps: those read SQLite's clock through the VFS rather than the SQL-function layer, so (dev builds only) connections open against a wrapping VFS that is a byte-for-byte copy of the default VFS with only its current-time hooks overridden to return the frozen instant — all file I/O still delegates to the genuine OS VFS unchanged. There are no remaining unfrozen `'now'` paths.
- **The test clock is impossible to enable on a production build.** It is compiled in only when the `dev_clock` build option is true (on in `Debug`, off in any release build; the release script ships it off). A production binary never reads `ZIGBASE_FAKE_NOW` — the override folds to a comptime no-op — so time can never be frozen in production.

## Platform & UI
- **No Windows build** — Linux and macOS only (the embedded HTTP server depends on facil.io/zap).
- **Admin UI:** no logs screen, and the record editor uses a plain textarea (no WYSIWYG rich-text editor) — both deferred.

## Static file serving

- Static files are served without authentication — collection access rules do not
  apply to the static root; use file storage for access-controlled delivery.
- No `Range`/partial-content requests (no video seeking on large files served from
  the static root).
- No directory listings; directories resolve to `index.html` or 404.
- Path safety is lexical (`..`, backslashes, and NUL bytes are rejected) **and**
  symlink-aware: a served file is canonicalized and refused if its real path escapes
  the configured static root, so a symlink inside the root pointing outside it is not
  followed out (F10).
- No on-the-fly compression; pre-compress at the CDN or reverse proxy if needed.
- In **dir** mode (`--serve-static` or comptime `.dir`), caching is controlled by
  facil.io's `sendFile` (fixed `Cache-Control: max-age=3600`) — this value is not
  configurable yet.

## Other deferred work
- Image thumbnails / transforms; an S3 (or other remote) storage backend — a pluggable `.storage` slot exists, but only the local-disk backend ships; `fields=` response projection; resumable/chunked uploads; realtime backfill/replay and per-event-guard load-tuning.

---
These are tracked for upcoming releases. Contributions welcome.
