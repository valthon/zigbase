---
title: Configuration
description: The full environment-variable reference, the CLI commands, and the configuration precedence rules for the ZigBase server.
order: 3
group: guides
---

# Configuration

ZigBase is configured by environment variables and a small set of `serve` command-line
flags.

## Precedence

Configuration resolves in order of **increasing precedence**:

1. **Built-in defaults**
2. **Environment variables**
3. **`serve` command-line flags** (where a flag exists)

So a flag overrides the matching environment variable, which overrides the default.

## CLI commands

```text
zigbase serve [--http-host H] [--http-port N] [--data-dir PATH] [--serve-static DIR]
              [--insecure-cookies] [--trust-proxy] [--realtime-origins CSV]
zigbase migrate [--data-dir PATH]
zigbase superuser create --email E --password P [--data-dir PATH]
zigbase help
```

Running `zigbase` with no recognised command prints usage.

- **`serve`** — start the HTTP server. The `--serve-static DIR` flag enables static file
  serving from `DIR` at the root path (anything not matching `/api/`, `/_/`, or custom
  routes). Only available when the app uses the default static-files mode (field absent in
  `App(.{...})`); rejected as an unknown flag when the mode is comptime-hardcoded
  (`.disabled`, `.dir`, or `.embedded`).
  A directory in the static tree containing an empty file named `.spa` becomes an
  SPA root: any GET/HEAD miss at or below it serves that directory's `index.html`
  (200) so client-routed apps survive deep links and hard refreshes — resolved live
  against the filesystem on every miss (add/remove a marker with no restart needed);
  startup only fails fast if a marker has no `index.html`. Real files and
  `/api`/admin paths always win. See
  [Framework → Static files](./framework#13-serve-a-frontend-static-files).
- **`migrate`** — run schema migrations against the data directory and exit.
- **`superuser create`** — create a superuser (required before managing collections).
- **`help`** — print usage.

## Environment variables

| Env var | Flag | Default | Purpose |
| --- | --- | --- | --- |
| `ZIGBASE_HTTP_HOST` | `--http-host` | `127.0.0.1` | bind address (loopback by default; set `0.0.0.0` for all interfaces) |
| `ZIGBASE_HTTP_PORT` | `--http-port` | `8090` | listen port |
| `ZIGBASE_DATA_DIR` | `--data-dir` | `./zb_data` | data directory (holds `data.db` and `storage/`) |
| `ZIGBASE_DB_URL` | — | `""` (SQLite) | **Experimental, opt-in.** A `postgres://…` URL selects the PostgreSQL backend instead of SQLite. Only honored in a binary built with `-Dpostgres=true` (see below); ignored otherwise |
| — | `--serve-static` | `""` (off) | serve static files from DIR at the root path (default mode only) |
| `ZIGBASE_JWT_SECRET` | — | _auto-generated_ | token signing secret (≥32 bytes). Unset → a random secret is generated + persisted at `<data-dir>/.jwt_secret` (0600); a shorter provided value is refused |
| `ZIGBASE_COOKIE_SECURE` | `--insecure-cookies` (sets `false`) | `true` | mark auth cookies `Secure`. On by default; opt out for plain-HTTP local dev |
| `ZIGBASE_TRUST_PROXY` | `--trust-proxy` (sets `true`) | `false` | trust `X-Forwarded-For`/`X-Real-IP` for client-IP / rate-limit keying (set only behind a trusted reverse proxy) |
| `ZIGBASE_AUTH_TOKEN_TTL` | — | `1209600` (14 days) | auth token lifetime, seconds |
| `ZIGBASE_VERIFICATION_TTL` | — | `604800` (7 days) | email-verification token lifetime, seconds |
| `ZIGBASE_PASSWORD_RESET_TTL` | — | `3600` (1 hour) | password-reset token lifetime, seconds |
| `ZIGBASE_REALTIME_ORIGINS` | `--realtime-origins` | `""` (deny cross-origin) | CSV of allowed WebSocket `Origin`s. Empty denies cross-origin browser upgrades; same-origin upgrades are always allowed |
| `ZIGBASE_MAX_UPLOAD_SIZE` | — | `52428800` (50 MiB) | max request body size, bytes |
| `ZIGBASE_FILE_TOKEN_TTL` | — | `120` (2 min) | file-access token lifetime, seconds |
| `ZIGBASE_SENTRY_DSN` | — | `""` (log to stderr) | set to enable Sentry error reporting |
| `ZIGBASE_RATE_LIMIT_MAX` | — | `10` | max sensitive-auth attempts per window per client; `0` disables rate limiting |
| `ZIGBASE_RATE_LIMIT_WINDOW` | — | `60` | rate-limit window length, seconds |
| `ZIGBASE_SMTP_HOST` | — | `""` (use LogMailer) | SMTP server host; set to deliver verify/reset email instead of logging |
| `ZIGBASE_SMTP_PORT` | — | `25` | SMTP server port |
| `ZIGBASE_SMTP_USERNAME` | — | `""` | SMTP username; non-empty enables `AUTH LOGIN` |
| `ZIGBASE_SMTP_PASSWORD` | — | `""` | SMTP password |
| `ZIGBASE_SMTP_FROM` | — | `noreply@zigbase.dev` | envelope + `From:` address |
| `ZIGBASE_SMTP_TLS` | — | `auto` | transport security: `none` / `starttls` / `implicit` / `auto` (auto: 465→implicit, 587→starttls, else→none) |
| `ZIGBASE_SMTP_INSECURE` | — | `false` | skip TLS cert verification (self-signed relays only) |
| `ZIGBASE_SENDMAIL_COMMAND` | — | `""` (off) | local-MTA command to pipe mail to (e.g. `sendmail -t -i` or `msmtp -t`); when set, **overrides** SMTP. App holds no SMTP creds |
| `ZIGBASE_FAKE_NOW` | — | _unset_ | **DEV-ONLY test clock.** Freeze "now" to an ISO-8601 UTC instant (e.g. `2029-03-07T16:00:00Z`) for deterministic time-boundary e2e tests. Freezes both the framework's own timestamps and a consumer's raw SQL `datetime('now')` / `unixepoch('now')` / `strftime(…, 'now')` (and `date`/`time`/`julianday`), plus the `CURRENT_TIMESTAMP` / `CURRENT_TIME` / `CURRENT_DATE` keywords and column `DEFAULT CURRENT_TIMESTAMP` (via a wrapping VFS). **Ignored entirely on a production build** (compiled out unless built with `-Ddev-clock=true`; off in any release build). See [Known limitations → Testing](./known-limitations) for scope |
| `ZIGBASE_FAKE_SEED` | — | _unset_ | **DEV-ONLY seeded entropy.** Set to a decimal `u64` (e.g. `12345`) to make record/field ID and token generation deterministic: two runs with the same seed produce identical IDs and tokens. Useful for snapshot tests. **Ignored entirely on a production build** (compiled out unless built with `-Ddev-clock=true`; off in any release build). See [Framework → Test/dev-mode seams](./framework#14-test--dev-mode-determinism-seams) |

## Database backend (experimental)

ZigBase defaults to its embedded SQLite database (`<data-dir>/data.db`) — the single-binary
story, and the only backend in a stock build. A **pure-Zig PostgreSQL backend** (issue #159) is
being built behind the opt-in `-Dpostgres` build flag; it is **off by default** and adds **no
libpq, C, or OpenSSL** (TLS and SCRAM-SHA-256 use Zig `std` only), so the default binary stays
fully static and OpenSSL-free, with its SQLite data path unchanged.

When compiled in (`zig build -Dpostgres=true`), setting `ZIGBASE_DB_URL` to a
`postgres://user:pass@host:port/dbname?sslmode=require` URL selects PostgreSQL at startup; any
other value (or an unset var) keeps SQLite. The backend is chosen once, by connection string —
"switch via configuration alone". A **stock (`-Dpostgres=false`) binary** handed a `postgres://`
`ZIGBASE_DB_URL` does **not** silently write to local SQLite — it logs a prominent warning and
falls back to SQLite, so a misconfigured deployment is visible rather than misdirecting data.

This is **foundational scaffolding, not yet a supported deployment target**: full schema /
query / migration / realtime parity lands in follow-up PRs. Transport is also **not yet
authenticated** — `sslmode=require` encrypts but does not verify the server certificate/hostname
(libpq `require` parity), and `verify-ca`/`verify-full` are rejected — so use it only on a
trusted network path for now. Full documentation ships with the parity work.

## Email delivery

Three backends, selected by config with a fixed precedence (no code change to switch):

1. **`ZIGBASE_SENDMAIL_COMMAND` set** → the message (the same RFC822 bytes the SMTP backend
   sends) is piped to a **local command's stdin** and exit 0 means delivered. This is the
   standard "delegate delivery to a local MTA/relay, hold no SMTP credentials in the app"
   setup — point it at `sendmail -t -i` or `msmtp -t`. The string is whitespace-split into
   argv; `From:` still comes from `ZIGBASE_SMTP_FROM`. Takes precedence over SMTP.
2. **`ZIGBASE_SMTP_HOST` set** → verification and password-reset tokens are **emailed** over
   the configured SMTP transport (STARTTLS / implicit TLS / plaintext). TLS verifies
   certificates by default; `ZIGBASE_SMTP_INSECURE` disables verification for self-signed
   relays.
3. **Neither set** (the default) → tokens are **logged** to the server (a dev/CI convenience).

Configure a real backend (sendmail command or SMTP) for production.

## Rate limiting

Sensitive auth endpoints (login, verification, password-reset) are **rate limited** — see
[API → Rate limiting](./api#rate-limiting). `X-Forwarded-For` / `X-Real-IP` are **ignored by
default** (they are spoofable on direct exposure); the limiter keys on the submitted
identity/email. Set `--trust-proxy` / `ZIGBASE_TRUST_PROXY=true` **only** behind a trusted
reverse proxy to key on the proxy-supplied client IP; see
[Known limitations](./known-limitations).

## Security

ZigBase is **secure by default**. The bind is loopback (`127.0.0.1`); expose all interfaces
deliberately with `--http-host 0.0.0.0` (front it with a firewall / reverse proxy). The JWT
secret is per-deployment: leaving `ZIGBASE_JWT_SECRET` unset generates a strong random secret
and persists it at `<data-dir>/.jwt_secret` (mode 0600), reused on later runs; a provided
secret must be ≥32 bytes or the server refuses to start. Auth cookies are `Secure` by default,
so plain-HTTP local dev needs `--insecure-cookies` (or `ZIGBASE_COOKIE_SECURE=false`) or the
admin-UI login cookie is not stored. An empty `ZIGBASE_REALTIME_ORIGINS` **denies** cross-origin
browser WebSocket upgrades; same-origin upgrades (the embedded admin UI, or a frontend served
from the same binary) are always allowed, so only a separate-origin frontend needs
`--realtime-origins`.

## See also

- [Quick start](./quick-start) — install and serve.
- [API](./api) — the REST + WebSocket reference.
- [Known limitations](./known-limitations) — caveats around email, rate limiting, and more.
