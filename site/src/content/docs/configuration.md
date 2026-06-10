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
zigbase serve [--http-host H] [--http-port N] [--data-dir PATH]
zigbase migrate [--data-dir PATH]
zigbase superuser create --email E --password P [--data-dir PATH]
zigbase help
```

Running `zigbase` with no recognised command prints usage.

- **`serve`** — start the HTTP server.
- **`migrate`** — run schema migrations against the data directory and exit.
- **`superuser create`** — create a superuser (required before managing collections).
- **`help`** — print usage.

## Environment variables

| Env var | Flag | Default | Purpose |
| --- | --- | --- | --- |
| `ZIGBASE_HTTP_HOST` | `--http-host` | `0.0.0.0` | bind address |
| `ZIGBASE_HTTP_PORT` | `--http-port` | `8090` | listen port |
| `ZIGBASE_DATA_DIR` | `--data-dir` | `./zb_data` | data directory (holds `data.db` and `storage/`) |
| `ZIGBASE_JWT_SECRET` | — | `dev-insecure-secret-change-me` | token signing secret (set in production) |
| `ZIGBASE_COOKIE_SECURE` | — | `false` | mark auth cookies `Secure` (enable behind HTTPS) |
| `ZIGBASE_AUTH_TOKEN_TTL` | — | `1209600` (14 days) | auth token lifetime, seconds |
| `ZIGBASE_VERIFICATION_TTL` | — | `604800` (7 days) | email-verification token lifetime, seconds |
| `ZIGBASE_PASSWORD_RESET_TTL` | — | `3600` (1 hour) | password-reset token lifetime, seconds |
| `ZIGBASE_REALTIME_ORIGINS` | — | `""` (allow any) | CSV of allowed WebSocket `Origin`s |
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

## Email delivery

With `ZIGBASE_SMTP_HOST` set, verification and password-reset tokens are **emailed** over
the configured SMTP transport. Without it (the default), they are **logged** to the server
(a dev/CI convenience). Configure SMTP for production. TLS verifies certificates by default;
`ZIGBASE_SMTP_INSECURE` disables verification for self-signed relays.

## Rate limiting

Sensitive auth endpoints (login, verification, password-reset) are **rate limited** — see
[API → Rate limiting](./api#rate-limiting). The limiter is keyed on the proxy-supplied
client IP (`X-Forwarded-For` / `X-Real-IP`) with a per-identity fallback; see
[Known limitations](./known-limitations).

## Security

Set `ZIGBASE_JWT_SECRET` to a strong, random value in production. The server **refuses to
start** when the secret is left at its insecure default and `ZIGBASE_COOKIE_SECURE=true`;
with the default secret and `cookie_secure` off, it logs a warning instead. An empty
`ZIGBASE_REALTIME_ORIGINS` allows any WebSocket origin (fine for development, lock it down
in production).

## See also

- [Quick start](./quick-start) — install and serve.
- [API](./api) — the REST + WebSocket reference.
- [Known limitations](./known-limitations) — caveats around email, rate limiting, and more.
