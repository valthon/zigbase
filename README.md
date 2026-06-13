# ZigBase

ZigBase is a single-binary, PocketBase-inspired (but **not** API-compatible) backend in
**Zig 0.16**. It bundles a collections + schema engine, a typed records query API
(filter / sort / expand), per-collection access rules, authentication (argon2id password
plus OAuth2 with PKCE), realtime updates over WebSocket, local file storage, and an
embedded admin UI at `/_/` — all in one statically-linked executable backed by SQLite.
It is also an **embeddable Zig framework**: import it as a library and extend the server
with comptime record hooks, custom HTTP routes, and scheduled jobs.

`v0.4.0 — early release` · `License: Apache-2.0` · see [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)

**Website & docs:** <https://valthon.github.io/zigbase>

## Quickstart (run the binary)

```sh
mise install                                    # installs Zig 0.16.0 (pinned in mise.toml)
zig build                                        # -> zig-out/bin/zigbase   (or: mise exec zig@0.16.0 -- zig build)
./zig-out/bin/zigbase superuser create --email you@example.com --password "<a strong password>" --data-dir ./zb_data
# --insecure-cookies: local dev is over plain HTTP, and auth cookies are Secure by default.
./zig-out/bin/zigbase serve --insecure-cookies --data-dir ./zb_data
# open http://127.0.0.1:8090/_/  (admin UI) and sign in as the superuser
curl http://127.0.0.1:8090/api/health           # {"status":"ok"}
```

The default bind is `127.0.0.1:8090` (loopback only). To expose ZigBase on all
interfaces, pass `--http-host 0.0.0.0` (front it with a firewall / reverse proxy).
On first `serve` with no `ZIGBASE_JWT_SECRET`, a strong random secret is generated and
persisted at `<data-dir>/.jwt_secret` (mode 0600), then reused on later runs. Your `zig`
must be 0.16.0 — either activate mise (`eval "$(mise activate bash)"`) or prefix commands
with `mise exec zig@0.16.0 --`.

## Features

- **Collections & schema** — define collections with typed fields; schema migrations run on startup.
- **Records & query API** — typed CRUD with `filter`, `sort`, and `expand` on relations. → [docs/api.md](docs/api.md)
- **Access rules** — per-collection list / view / create / update / delete rules. → [docs/api.md](docs/api.md)
- **Auth** — argon2id password auth, JWT tokens, verification and password-reset flows. → [docs/api.md](docs/api.md)
- **OAuth2** — Authorization-Code + PKCE provider login and account linking. → [docs/api.md](docs/api.md)
- **Realtime** — subscribe to record changes over WebSocket. → [docs/api.md](docs/api.md)
- **Files** — local file storage with serving and short-lived file-access tokens. → [docs/api.md](docs/api.md)
- **Static files** — serve a frontend from the same binary: `--serve-static <dir>` at runtime, or pin/embed it at comptime. → [docs/framework.md](docs/framework.md)
- **Admin UI** — embedded single-page app served at `/_/`. → [docs/api.md](docs/api.md)
- **Framework** — comptime record hooks, custom routes, scheduled jobs, a comptime schema (with additive auto-migration), and pluggable storage/mailer backends. → [docs/framework.md](docs/framework.md)
- **Email** — pluggable SMTP mailer (STARTTLS / implicit TLS / plaintext) delivering verification and password-reset email; logs the tokens in dev when SMTP is unset. → [docs/api.md](docs/api.md)

## Build an app on ZigBase (use it as a library)

Fetch ZigBase as a dependency:

```sh
zig fetch --save git+https://github.com/valthon/zigbase
```

Wire the module into your `build.zig` (ZigBase links libc):

```zig
const zb = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zigbase", zb.module("zigbase"));
exe_mod.link_libc = true;
```

Then build your own backend on top of it — here a `beforeCreate` hook on the `posts`
collection:

```zig
const zigbase = @import("zigbase");

fn slugify(ev: *zigbase.RecordEvent) anyerror!void {
    // mutate ev.record using ev.arena ...
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
    }).runCli(init);
}
```

`runCli` gives your binary the same `serve` / `migrate` / `superuser create` / `help`
commands as the stock server. Beyond hooks, `App(.{...})` also accepts a comptime
**schema** (`.collections` + `.migrations`, provisioned at startup with additive
auto-migration), **pluggable backends** (`.storage` / `.mailer`), and **footprint
levers** (`.pools`). See [docs/framework.md](docs/framework.md) and the worked
examples: [examples/blog/](examples/blog/) (basic packaging — default
`--serve-static` mode), [examples/golfsim/](examples/golfsim/) (a real app —
comptime-hardcoded `.dir` static mode), and [examples/plugins/](examples/plugins/)
(advanced framework features — custom plugins, comptime schema, typed migrations,
pool levers — fully embedded static assets via `embedStaticDir`). Each example ships
an Astro + React frontend demonstrating a different static-files mode.

## CLI

```
zigbase serve [--http-host H] [--http-port N] [--data-dir PATH] [--serve-static DIR]
              [--insecure-cookies] [--trust-proxy] [--realtime-origins CSV]
zigbase migrate [--data-dir PATH]
zigbase superuser create --email E --password P [--data-dir PATH]
zigbase help
```

Running `zigbase` with no recognised command prints usage.

## Configuration

Configuration resolves in order of increasing precedence: built-in defaults, then
environment variables, then `serve` command-line flags (where a flag exists).

| Env var | Flag | Default | Purpose |
|---|---|---|---|
| `ZIGBASE_HTTP_HOST` | `--http-host` | `127.0.0.1` | bind address (loopback by default; set `0.0.0.0` for all interfaces) |
| `ZIGBASE_HTTP_PORT` | `--http-port` | `8090` | listen port |
| `ZIGBASE_DATA_DIR` | `--data-dir` | `./zb_data` | data directory (holds `data.db`, `storage/`, and `.jwt_secret`) |
| `ZIGBASE_JWT_SECRET` | — | _auto-generated_ | token signing secret (≥32 bytes). Unset → a random secret is generated + persisted at `<data-dir>/.jwt_secret` (0600); a shorter provided value is refused |
| `ZIGBASE_COOKIE_SECURE` | `--insecure-cookies` (sets `false`) | `true` | mark auth cookies `Secure`. On by default; opt out for plain-HTTP local dev |
| `ZIGBASE_TRUST_PROXY` | `--trust-proxy` (sets `true`) | `false` | trust `X-Forwarded-For`/`X-Real-IP` for client-IP / rate-limit keying (set only behind a trusted reverse proxy) |
| `ZIGBASE_AUTH_TOKEN_TTL` | — | `1209600` (14 days) | auth token lifetime, seconds |
| `ZIGBASE_VERIFICATION_TTL` | — | `604800` (7 days) | email-verification token lifetime, seconds |
| `ZIGBASE_PASSWORD_RESET_TTL` | — | `3600` (1 hour) | password-reset token lifetime, seconds |
| `ZIGBASE_REALTIME_ORIGINS` | `--realtime-origins` | `""` (deny cross-origin) | CSV of allowed WebSocket `Origin`s. Empty denies cross-origin browser upgrades |
| `ZIGBASE_MAX_UPLOAD_SIZE` | — | `52428800` (50 MiB) | max request body size, bytes |
| `ZIGBASE_FILE_TOKEN_TTL` | — | `120` (2 min) | file-access token lifetime, seconds |
| `ZIGBASE_SENTRY_DSN` | — | `""` (log to stderr) | set to enable Sentry error reporting |
| `ZIGBASE_RATE_LIMIT_MAX` | — | `10` | max sensitive-auth attempts per window per client; `0` disables rate limiting |
| `ZIGBASE_RATE_LIMIT_WINDOW` | — | `60` | rate-limit window length, seconds |
| `ZIGBASE_OAUTH_STATE_SERVER` | — | `false` | enable server-side OAuth `state` (CSRF) store; clients must call `oauth2-init` and echo `state` on callback (PKCE still required) |
| `ZIGBASE_OAUTH_STATE_TTL` | — | `600` (10 min) | server-side OAuth `state` lifetime, seconds |
| `ZIGBASE_SMTP_HOST` | — | `""` (use LogMailer) | SMTP server host; set to deliver verify/reset email instead of logging |
| `ZIGBASE_SMTP_PORT` | — | `25` | SMTP server port |
| `ZIGBASE_SMTP_USERNAME` | — | `""` | SMTP username; non-empty enables `AUTH LOGIN` |
| `ZIGBASE_SMTP_PASSWORD` | — | `""` | SMTP password |
| `ZIGBASE_SMTP_FROM` | — | `noreply@zigbase.dev` | envelope + `From:` address |
| `ZIGBASE_SMTP_TLS` | — | `auto` | transport security: `none` / `starttls` / `implicit` / `auto` (auto: 465→implicit, 587→starttls, else→none) |
| `ZIGBASE_SMTP_INSECURE` | — | `false` | skip TLS cert verification (self-signed relays only) |

> Email delivery: with `ZIGBASE_SMTP_HOST` set, verification and password-reset tokens
> are **emailed** over the configured SMTP transport. Without it (the default), they are
> **logged** to the server (a dev/CI convenience). Configure SMTP for production. TLS
> verifies certificates by default; `ZIGBASE_SMTP_INSECURE` disables verification for
> self-signed relays.
>
> Sensitive auth endpoints (login, verification, password-reset) are **rate limited** —
> see [docs/api.md → Rate limiting](docs/api.md#rate-limiting).

## Security

ZigBase is **secure by default**:

- **Bind** is loopback (`127.0.0.1`). Expose it deliberately with `--http-host 0.0.0.0`
  behind a firewall / reverse proxy.
- **JWT secret** is per-deployment: leaving `ZIGBASE_JWT_SECRET` unset generates a strong
  random secret and persists it at `<data-dir>/.jwt_secret` (0600), reused on later runs.
  A provided secret must be ≥32 bytes; anything shorter is refused. There is no shared
  default secret. Override the env var to manage the secret yourself (e.g. a secrets store).
- **Auth cookies** are `Secure` by default (HTTPS-only). For plain-HTTP local dev, pass
  `--insecure-cookies` (or `ZIGBASE_COOKIE_SECURE=false`).
- **Realtime origins**: an empty `ZIGBASE_REALTIME_ORIGINS` **denies** cross-origin browser
  WebSocket upgrades. **Same-origin upgrades are always allowed** — the embedded admin UI and any
  frontend served from this same binary work out of the box. A request with no `Origin` header
  (a non-browser client) is also allowed. Set explicit origins only for a *separate-origin*
  browser app.
- **Rate limiting / client IP**: `X-Forwarded-For` / `X-Real-IP` are ignored unless
  `--trust-proxy` (`ZIGBASE_TRUST_PROXY=true`) is set, so direct exposure can't be bypassed
  by spoofing those headers. Enable it only behind a trusted reverse proxy.

## Project layout

```
build.zig, build.zig.zon   build graph; vendors SQLite, depends on zap
src/
  framework.zig            App(cfg) builder + CLI/serve entry points
  server.zig               built-in HTTP route table; zap adapter
  config.zig               Config struct + env loader
  cli.zig                  argv parser
  app.zig, events.zig      runtime app + hook/route/job dispatch
  collections.zig, schema.zig, records.zig, rules.zig
  auth.zig, jwt.zig, crypto.zig, scheduler.zig, schedule.zig
  api/                     HTTP handlers (health, collections, records, auth, oauth, files)
  query/                   filter / sort / expand
  oauth/                   OAuth2 + PKCE client
  realtime/                WebSocket subscriptions
  files/                   local storage + multipart
  admin/                   embedded admin SPA (served at /_/)
examples/
  blog/                    basic packaging proof (hook, custom route, cron job, --serve-static Astro frontend)
  golfsim/                 a realistic app built on ZigBase (hooks, routes, cron, comptime .dir static frontend)
  plugins/                 advanced framework features (custom plugins, comptime schema, typed migrations, pools, embedded static frontend)
```

## Documentation

- [docs/tutorial.md](docs/tutorial.md) — **start here**: build an app on ZigBase, end to end (provision → rules → signup → records + file upload → custom route → cron)
- [docs/fields.md](docs/fields.md) — field-type & options catalog (all 12 types, defaults, validation rules)
- [docs/recipes.md](docs/recipes.md) — task recipes: ship a frontend in the binary, schema provisioning (curl), signup, owner/relation access rules, hooks, custom routes, DB access in cron
- [docs/api.md](docs/api.md) — HTTP API reference (collections, records, query, rules, auth, oauth2, realtime, files, static files, admin)
- [docs/framework.md](docs/framework.md) — embedding ZigBase: hooks, routes, jobs, static-file modes
- [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) — current caveats
- [CHANGELOG.md](CHANGELOG.md) — release history

## License

Apache-2.0.
