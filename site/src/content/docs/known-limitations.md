---
title: Known limitations
description: Current caveats in ZigBase — auth/email, framework hooks, schema migrations, fields, the scheduler, platform/UI gaps, and deferred work.
order: 3
group: reference
---

# Known limitations

ZigBase is an early release. The gaps below are known and tracked for future releases.

## Auth & email

- **Per-device session list/revoke requires opt-in `.auth.session.store = .table`; the default is
  still `.epoch`.** The default `App(.{ .auth = .{ .session = .{ .store = .epoch } } })` revokes per **principal**
  via the token epoch — `revokeAllSessions()` ("log out everywhere"), `refresh()`, `rotate()`
  — stateless, with zero extra DB work and unchanged token format. Opting into
  `App(.{ .auth = .{ .session = .{ .store = .table } } })` adds a server-side `_sessions` store enabling
  per-device list/revoke, at the cost of **one extra read per authenticated request** (the
  documented trade-off; flipping the default awaits real-world perf data). The surface now
  spans three layers, all gated the same way: the `ctx.auth()` verbs (`listActiveSessions()` /
  `revoke(sessionId)`), the REST endpoints (`GET`/`DELETE /api/collections/:col/auth/sessions[/:sid]`),
  and the TypeScript SDK (`listSessions()` / `revokeSession(id)`). In `.epoch` mode,
  `ctx.auth()` returns `error.SessionStoreNotEnabled` and the REST/SDK surface returns a
  non-oracle `404`.
- **A mail delivery path must be configured for production.** Verification and password-reset
  email is delivered once a mailer is configured. Zero-code options selectable by env: **SMTP**
  (`ZIGBASE_SMTP_HOST` + friends; `none` / `starttls` / `implicit` TLS — certificates verified by
  default, `ZIGBASE_SMTP_INSECURE` disables verification for self-signed relays only), or a
  **local sendmail/msmtp-style command** (`ZIGBASE_SENDMAIL_COMMAND`, e.g. `msmtp -t` or
  `sendmail -t -i`; whitespace-split into argv, and it takes precedence over SMTP when set).
  Embedded consumers can also swap in the built-in **SES** / **Postmark** backends or a custom
  `Mailer` plugin via `App(.{ .mailer = T })`. **With none configured, those tokens are logged
  to the server** (the dev/CI default) rather than emailed — a real deployment must configure one
  of the above.
- **Rate limiting keys on proxy headers only when `--trust-proxy` is set.** Login /
  verification / password-reset are rate limited. `X-Forwarded-For` / `X-Real-IP` are
  **ignored by default** (they are spoofable on direct exposure); set `--trust-proxy` /
  `ZIGBASE_TRUST_PROXY=true` only behind a trusted reverse proxy to honor them. Without a
  trusted proxy the limiter keys on the submitted identity/email (not header-spoofable). The
  limiter also fails open under memory pressure (it never becomes a self-DoS), so it is a
  throttle, not a hard guarantee.
- **Queue `.rate` throttling is per-process, in-memory.** A durable queue's `.rate = .{
  .per_second = N }` token bucket lives in the serving process's memory — it is authoritative
  only because the scheduler is itself single-process (see Scheduler below); coordinating a
  shared rate ceiling across multiple ZigBase processes is out of scope.
- **Durable mail delivery is at-least-once: a crash can produce one duplicate send.** Both
  the built-in `"mail"` job kind and bulk `sendBulk` delivery persist to a durable queue and
  mark their row `sent`/`done` only after the backend accepts the message; a crash between
  backend-accept and that row update replays the job on restart, producing one duplicate send
  to the recipient. Handlers are otherwise idempotent (bulk redelivery of an already-`sent`/
  `suppressed`/`canceled` recipient row is a no-op) — this window is the one unavoidable
  exception.
- **No CSS inliner or `cid:` inline attachments.** ZigBase does not inline `<style>` rules
  into `style="…"` attributes or support MIME `cid:`-referenced inline images — author inline
  styles directly (or run a build-time inliner over your template sources) and host images at
  absolute HTTPS URLs; see "HTML that renders everywhere" in
  [Framework](./framework#ctxmail--send-application-mail).

## Framework / hooks

- **`before`-hook side-writes are atomic with the triggering write; copy `ctx.records()` results
  into `ev.arena` before storing them in `ev.record`.** On the HTTP create/update/delete path a
  `before`-hook runs *inside* the triggering write's transaction, so its `ctx.records()`
  side-writes commit atomically with the primary write and roll back together if the hook errors
  or the access rule denies (fail closed). The one caveat: values *returned* by `ctx.records()`
  (e.g. a `.get` result) live on the hook's per-invocation arena, which is freed when the hook
  returns — not on `ev.arena`, which owns `ev.record` and outlives the hook. Copy such a value
  into `ev.arena` before storing it into `ev.record`, or it will dangle.

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
- **`app.submit` and memory-queue jobs run on a small bounded in-process worker pool**
  (drained and joined at shutdown, so tasks submitted before shutdown complete). The ring is
  bounded: overflow is rejected with `error.QueueFull` rather than blocking the caller, and a
  retrying memory job holds one pool worker for its whole backoff — put sustained
  high-volume or long-retry work on a durable queue.
- **Background-job queue delivery semantics (`.queues`/`ctx.enqueue`).** *Durable* queues are
  **at-least-once**: a job whose handler exceeds its queue's `visibility_timeout_s`, or that
  crashes after a side effect but before completion, may run **more than once** — make
  durable handlers **idempotent** (set `visibility_timeout_s` above the queue's longest job
  runtime, and use an idempotency key for external effects). Durable workers **poll** (~0.5s
  cadence), so jobs drain with low but non-zero latency, and a worker's `concurrency` is a
  per-cycle batch processed serially (parallelism = more workers). *Memory* queues are
  **at-most-once across restart** (in-RAM only; lost on crash/shutdown) and run on the
  bounded worker pool (a full ring rejects new jobs with `error.QueueFull`); use a durable
  queue when a job must survive a restart or for sustained throughput.
- **TTL record physical deletion is eventually consistent (~5 minutes), but expired rows are
  hidden from reads immediately.** Expired rows in a `.ttl_field` collection are
  **automatically excluded from every read** (list, get, relation expand — via the HTTP API and
  `ctx.records()`) by a read-time predicate that is ANDed with your filter, access rule, and
  keyset cursor, so no manual `expires_at > @now` filter is needed. Physical deletion is still
  handled by an internal GC job that runs once at startup and then on the `.ttl_gc_interval`
  cadence (default **every 5 minutes**, tunable via the comptime `.ttl_gc_interval` App config
  key), so an expired row may persist in the table until the next sweep —
  but it is never returned by a read in the meantime. A row whose ttl field is `null` never
  expires; a row with an unparseable ttl value is fail-safe (stays visible, never reaped).

## Testing & determinism

- **The `ZIGBASE_FAKE_NOW` test clock freezes the framework's clock AND consumer SQL `'now'`.**
  Setting `ZIGBASE_FAKE_NOW` to an ISO-8601 UTC instant (dev builds only) freezes every "now"
  the framework controls — token `iat`/`exp`, the scheduler's next-fire math, the auth
  rate-limiter wall clock, and the auth-challenge / keyset-cursor TTL and expiry checks. As of
  the consumer-SQL determinism work, it **also** freezes a consumer's own raw
  `datetime('now')` / `unixepoch('now')` / `strftime(…, 'now')` (and `date`/`time`/`julianday`,
  including their zero-argument implicit-`'now'` forms): those date/time builtins are shadowed
  on every reader and writer connection so they resolve to the frozen instant, while every
  other input (explicit datetimes, `'+1 day'` modifiers, the `strftime` format string) passes
  through to genuine SQLite. It **also** freezes the SQL keywords `CURRENT_TIMESTAMP` /
  `CURRENT_TIME` / `CURRENT_DATE` and column `DEFAULT CURRENT_TIMESTAMP` timestamps: those read
  SQLite's clock through the VFS rather than the SQL-function layer, so (dev builds only)
  connections open against a wrapping VFS that is a byte-for-byte copy of the default VFS with
  only its current-time hooks overridden to return the frozen instant — all file I/O still
  delegates to the genuine OS VFS unchanged. There are no remaining unfrozen `'now'` paths.
- **The test clock is impossible to enable on a production build.** It is compiled in only when
  the `dev_clock` build option is true (on in `Debug`, off in any release build; the release
  script ships it off). A production binary never reads `ZIGBASE_FAKE_NOW` — the override folds
  to a comptime no-op — so time can never be frozen in production.
- **`ZIGBASE_FAKE_SEED` seeds ID/token generation for snapshot-test reproducibility.**
  Setting `ZIGBASE_FAKE_SEED` to a decimal `u64` on a dev build plants a deterministic
  Xoshiro256++ PRNG as the entropy source for all record IDs, field IDs, and token keys
  (`id.generate` / `crypto.genToken`). Two runs with the same seed produce byte-for-byte
  identical IDs and tokens. Other randomness (AEAD nonces, OTP digits, WebAuthn challenges)
  is **not** seeded — those are security-critical and reproducibility there is not supported.
  Like `ZIGBASE_FAKE_NOW`, the seeded path is compiled out on a production build (gated by
  the same `dev_clock` build option); a production binary always uses the OS CSPRNG for ID
  generation and cannot be seeded.

## Static file serving

- Static files are served without authentication — collection access rules do not apply
  to the static root; use file storage for access-controlled delivery.
- No directory listings; directories resolve to `index.html` or 404.
- Path safety is lexical (`..`, backslashes, and NUL bytes are rejected) **and**
  symlink-aware: a served file is canonicalized and refused if its real path escapes the
  configured static root, so a symlink inside the root pointing outside it is not followed
  out.
- Percent-encoded file names are not decoded: the request path reaches the static layer
  raw, so a file whose URL requires encoding (`my file.pdf` → `/my%20file.pdf`) is not
  servable (404). Encoded traversal (`%2e%2e`) stays a literal — and harmless — path
  segment for the same reason.
- No on-the-fly compression; pre-compress at the CDN or reverse proxy if needed.
- In **dir** mode, conditional requests (`If-None-Match`/`If-Range`) are delegated to
  facil.io's `sendFile`, which uses its own exact-match ETag semantics (an unquoted
  base64 size^mtime tag), not RFC 7232 list/weak comparison. A ranged request with a
  **matching** `If-Range` correctly resumes (`206`) — zigbase neutralizes an inverted
  branch in the vendored facil.io that otherwise deleted the `Range` on a match and
  forced a full `200` (RFC 9110 §13.1.5). The one residual: a ranged request with a
  **stale/mismatched** `If-Range` still returns `206` rather than the RFC-mandated full
  `200`, because facil.io's dir-mode ETag is seeded from process-local (ASLR'd)
  addresses and so cannot be recomputed and compared in zigbase's layer. **Owned** file
  serving is fully RFC-correct here: record-file downloads (`/api/files/…`) and
  **embedded** static assets mint and strong-compare their own `ETag`, so a mismatched
  `If-Range` there ignores the `Range` and returns `200`.

## Platform & UI

- **No Windows build** — Linux and macOS only (the embedded HTTP server depends on
  facil.io/zap).
- **Admin UI:** the record editor uses a plain textarea for `editor`- and `json`-type fields
  (no WYSIWYG rich-text editor), deferred. The Logs & realtime view is capability-gated — it
  appears only when the app enables `.analytics` (so it's hidden on the stock `zigbase serve`
  binary).

## Postgres backend

- **`verify-full` hostname checks match DNS names only.** Dialing an IP literal under
  the default `sslmode=verify-full` generally fails hostname verification even when
  the certificate carries an iPAddress SAN — connect by DNS name, or use
  `sslmode=verify-ca` on an otherwise-trusted path. Client certificates (mTLS),
  CRL/OCSP, and SCRAM channel binding (`SCRAM-SHA-256-PLUS`) are not supported.
- **SCRAM passwords that require NFKC normalization are rejected, not normalized.**
  The driver implements RFC 4013 SASLprep except the final NFKC normalization step: a
  password whose SASLprep output would need real NFKC normalization (e.g. U+2168 ROMAN
  NUMERAL NINE → `IX`, or U+00AA FEMININE ORDINAL INDICATOR → `a`) fails at connect
  with `error.PasswordNeedsNormalization` rather than being normalized. Real
  PostgreSQL's `pg_saslprep` *would* normalize and accept such a password; ZigBase
  deliberately hard-errors instead — a loud, actionable failure that names the fix is
  chosen over silently deriving a wrong SCRAM hash and returning an opaque auth
  failure. Supply the password pre-normalized to NFKC, or use an ASCII password.
  (Everything else is correctly prepped or intentionally matches PostgreSQL's own
  use-verbatim behavior.)
- **`migrate-db`: the superuser fast path is faster; the non-superuser path is fully
  supported.** A superuser target suspends FK enforcement wholesale; a non-superuser
  target provisions cycle-edge FKs as deferrable and defers them to COMMIT — correct
  for cyclic and self-referential graphs, verified against live Postgres in CI.

## S3 storage (`-Ds3`)

- **`PutObject` runs inside the global write transaction.** A file upload's S3 `PUT`
  happens synchronously while the writer lock is held — deliberate: a storage failure
  rolls the record write back instead of leaving an orphaned DB row pointing at a
  never-uploaded object.
- **Deletes are best-effort.** Exactly like local storage, a delete that fails partway
  can leave an orphaned object behind; there is no reconciliation job. Configure an S3
  lifecycle rule on the bucket/prefix as the mitigation.
- **Proxy-only serving.** Downloads always flow through the server's spool cache — there
  is no presigned-URL redirect mode yet.
- **Single-`PUT` uploads only, capped at 5 GiB.** There is no S3 multipart upload;
  `ZIGBASE_MAX_UPLOAD_SIZE` above the 5 GiB single-`PUT` limit is refused at startup.
- **Spool cache eviction is create-time, not true LRU.** Eviction sorts by file mtime,
  which is only set on a cache miss (the download that fills the entry) — a cache hit
  does not bump it, so a frequently-read file fetched once long ago can be evicted
  before a rarely-read file fetched more recently.

## Other deferred work

- Image thumbnails / transforms; `fields=` response projection; resumable/chunked
  uploads; realtime backfill/replay and per-event-guard load-tuning.

---

These are tracked for future releases. Contributions welcome.
