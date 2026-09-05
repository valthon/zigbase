# ZigBase

ZigBase is a single-binary, PocketBase-inspired (but **not** API-compatible) backend in
**Zig 0.16**. It bundles a collections + schema engine, a typed records query API
(filter / sort / expand), per-collection access rules, authentication (argon2id password
plus OAuth2 with PKCE), realtime updates over WebSocket and SSE, local file storage, and an
embedded admin UI at `/_/` — all in one statically-linked executable, backed by embedded
SQLite by default with PostgreSQL as an opt-in build flag.
It is also an **embeddable Zig framework**: import it as a library and extend the server
with comptime record hooks, custom HTTP routes, and scheduled jobs.

[![Release](https://img.shields.io/github/v/release/valthon/zigbase)](https://github.com/valthon/zigbase/releases) · `early release` · `License: Apache-2.0` · see [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)

**Website & docs:** <https://valthon.github.io/zigbase>

## Quickstart (run the binary)

```sh
mise install                                    # installs Zig 0.16.0 (pinned in mise.toml)
zig build                                        # -> zig-out/bin/zigbase   (or: mise exec zig@0.16.0 -- zig build)
./zig-out/bin/zigbase superuser create --email you@example.com --password "<a strong password>" --data-dir ./zb_data
# --insecure-cookies: local dev is over plain HTTP, and auth cookies are Secure by default.
./zig-out/bin/zigbase serve --insecure-cookies --data-dir ./zb_data
# open http://127.0.0.1:8090/_/  (admin UI) and sign in as the superuser
curl http://127.0.0.1:8090/api/health           # {"status":"ok","backend":"sqlite","versions":{...}}
curl http://127.0.0.1:8090/api/meta             # public, unauthenticated capability probe (build/config facts + endpoint map)
```

Or start from a scaffold, with no install at all: `npx zigbase init`.

The default bind is `127.0.0.1:8090` (loopback only). To expose ZigBase on all
interfaces, pass `--http-host 0.0.0.0` (front it with a firewall / reverse proxy).
On first `serve` with no `ZIGBASE_JWT_SECRET`, a strong random secret is generated and
persisted at `<data-dir>/.jwt_secret` (mode 0600), then reused on later runs. Your `zig`
must be 0.16.0 — either activate mise (`eval "$(mise activate bash)"`) or prefix commands
with `mise exec zig@0.16.0 --`. Building with an unsupported Zig version fails at compile
time with a clear required-vs-actual message rather than a confusing deep-compile error.

## Docker

```sh
docker run -d -p 8090:8090 -v zigbase_data:/data ghcr.io/valthon/zigbase:latest
```

The official image (`ghcr.io/valthon/zigbase`) ships the same static binary as the release
tarballs. It's the supported path on Windows hosts (no native Windows build — see
[Known limitations](KNOWN_LIMITATIONS.md)) and for Docker-first self-hosters generally.
See [docs/docker.md](docs/docker.md) for the data-volume/non-root/healthcheck details.

## Features

- **Collections & schema** — define collections with typed fields; schema migrations run on startup.
- **Records & query API** — typed CRUD with `filter`, `sort`, and `expand` on relations. → [docs/api.md](docs/api.md)
- **OpenAPI export** — deterministic OpenAPI 3.1.2 JSON for live collection CRUD and framework-declared routes, with redacted secrets and honest access metadata. → [docs/openapi.md](docs/openapi.md)
- **Search** — ranked full-text search (`?search=`) over `.searchable` fields, composed into the same scoped query as every other list request. SQLite FTS5 is compiled in by default (`-Dfts5=false` drops it, ~250-400 KB, for lean builds with no `.searchable` fields); Postgres full-text search is unaffected. Opt-in `-Dvector` build adds nearest-neighbor `?vector=` KNN search on both backends. → [docs/search.md](docs/search.md)
- **Access rules** — per-collection list / view / create / update / delete rules. → [docs/api.md](docs/api.md)
- **Auth** — argon2id password, magic-link, OTP, and WebAuthn passkey auth; JWT tokens; verification and password-reset flows. → [docs/api.md](docs/api.md)
- **Two-factor authentication** — TOTP, WebAuthn, and single-use recovery codes; require it for everyone, selected users/groups, or voluntary enrollment. Factor selection and policy hooks are comptime-configurable. → [docs/framework.md](docs/framework.md#two-factor-authentication)
- **Session management** — stateless epoch-based revocation (`revokeAllSessions` / `refresh` / `rotate`); opt-in per-device table store (`listActiveSessions` / `revoke(sessionId)`). → [docs/framework.md](docs/framework.md)
- **Auth lifecycle hooks** — `beforeAuthSuccess` / `beforeRegister` / `afterRegister` hooks intercept and extend the auth pipeline. → [docs/framework.md](docs/framework.md)
- **OAuth2** — Authorization-Code + PKCE provider login and account linking. → [docs/api.md](docs/api.md)
- **Field encryption** — per-field AES-256-GCM at-rest encryption; `zigbase rewrap` rotates keys without downtime. → [docs/fields.md](docs/fields.md)
- **TTL / expiry** — collections with a `.ttl_field` have expired records reaped automatically by an internal GC job. → [docs/framework.md](docs/framework.md)
- **KV store & feature flags** — lightweight typed key-value store with a built-in flag layer; manageable from the admin Settings UI. → [docs/framework.md](docs/framework.md)
- **Rate limiting** — global sensitive-auth limiter plus per-method custom limits; configurable window and count. → [docs/api.md](docs/api.md)
- **Realtime** — subscribe to record changes over WebSocket or SSE (EventSource — no SDK needed). → [docs/api.md](docs/api.md)
- **Files** — local file storage with serving and short-lived file-access tokens; opt-in S3-compatible storage (`-Ds3` build flag — AWS S3, MinIO, Cloudflare R2) selected by `ZIGBASE_S3_*` config alone, served through the same Range/ETag/tenancy-identical download path via a local spool cache. → [docs/api.md](docs/api.md)
- **TypeScript SDK** — published official client (`@zigbase/client`): auth, records,
  offset + cursor pagination, files, realtime + live store — plus a fully-typed client
  generated from your schema (`zig build gen-client`) or from any running instance
  (`npx @zigbase/typegen`). → [docs/typescript-sdk.md](docs/typescript-sdk.md)
- **Dart SDK** — official client (`zigbase_client`) for the Dart VM, Flutter, and Flutter web:
  auth + pluggable stores, records, offset + cursor pagination, files, and realtime
  subscriptions over WebSocket. Not yet published to pub.dev (git dependency for now).
  → [docs/dart-sdk.md](docs/dart-sdk.md)
- **Python SDK** — official client (`zigbase`): sync `ZigBase` and async `AsyncZigBase`
  facades over `httpx`, covering auth + pluggable stores, records, offset + cursor
  pagination, files, and accounts/analytics/senders. Not yet published to PyPI (git
  dependency for now). → [docs/python-sdk.md](docs/python-sdk.md)
- **Kotlin SDK** — official client (`io.github.valthon:zigbase-client`): a coroutine-first
  `ZigbaseClient` over Ktor, covering auth + pluggable stores, records, offset + cursor
  pagination, files, and accounts/analytics/senders. Not yet published to Maven Central
  (build `publishToMavenLocal` for now). → [docs/kotlin-sdk.md](docs/kotlin-sdk.md)
- **Static files** — serve a frontend from the same binary: `--serve-static <dir>` at runtime, or pin/embed it at comptime, with `.spa` SPA-fallback markers for client-routed apps. → [docs/framework.md](docs/framework.md)
- **Admin UI** — embedded single-page app served at `/_/`, including a Settings / Feature-Flags screen. → [docs/api.md](docs/api.md)
- **Framework** — `ctx`-first hooks, routes, and jobs expose a structured capability object (`ctx.records()`, `ctx.auth()`, `ctx.tx()`, `ctx.http()`, `ctx.kv()`) alongside comptime schema, additive auto-migration, and pluggable storage/mailer backends. → [docs/framework.md](docs/framework.md)
- **Determinism & test seam** — `ZIGBASE_FAKE_NOW` freezes the framework clock and all SQLite `'now'` paths; `ZIGBASE_FAKE_SEED` makes ID/token generation reproducible; `testcapture` intercepts sent mail and outbound HTTP in tests. Compiled out on production builds. → [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)
- **Email** — pluggable SMTP mailer (STARTTLS / implicit TLS / plaintext) delivering verification and password-reset email; logs the tokens in dev when SMTP is unset. → [docs/api.md](docs/api.md)

## Build an app on ZigBase (use it as a library)

Scaffold a project — `build.zig` already wired, a comptime schema, in-process
tests, and an `AGENTS.md`:

```sh
npx zigbase init --framework --dir myapp && cd myapp
zig fetch --save git+https://github.com/valthon/zigbase
zig build test
```

Or wire it into an existing package yourself:

```sh
zig fetch --save git+https://github.com/valthon/zigbase
```

```zig
const zigbase = @import("zigbase"); // the dependency's build.zig

const dep = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
zigbase.addTo(dep, exe_mod); // adds the import and wires the libc requirement — one call, nothing to remember

const tests = zigbase.addTest(b, dep, .{ .root_module = exe_mod });
b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
```

Then build your own backend on top of it — here a `beforeCreate` hook on the `posts`
collection:

```zig
const zigbase = @import("zigbase");

fn slugify(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    _ = ctx;
    // mutate ev.record using ev.arena.a ...
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
    }).runCli(init);
}
```

`runCli` gives your binary the same commands as the stock server — `serve`, `migrate`,
`migrate-db`, `import`, `schema`, `openapi`, `superuser create`, `rewrap`, `vapid-keygen`,
`explain-code`, `version`, and `help` (plus `typegen` when built with
`.enable_typegen = true`). Beyond hooks, `App(.{...})` also accepts a comptime
**schema** (`.collections` + `.migrations`, provisioned at startup with additive
auto-migration), **pluggable backends** (`.storage` / `.mailer`), and **footprint
levers** (`.pools`). See [docs/framework.md](docs/framework.md) and the worked
examples: [examples/blog/](examples/blog/) (basic packaging — default
`--serve-static` mode), [examples/golfsim/](examples/golfsim/) (a real app —
comptime-hardcoded `.dir` static mode), and [examples/plugins/](examples/plugins/)
(advanced framework features — custom plugins, comptime schema, typed migrations,
pool levers — fully embedded static assets via `embedStaticDir`). Each example ships
a Zigapagos + Preact frontend demonstrating a different static-files mode.

## CLI

```
zigbase serve [--http-host H] [--http-port N] [--data-dir PATH] [--serve-static DIR]
              [--insecure-cookies] [--trust-proxy] [--realtime-origins CSV]
              [--background] [--ephemeral] [--ignore-lock] [--force]
zigbase serve stop | status [--json] | logs [--follow] [--data-dir PATH]
zigbase migrate [status | rollback [N] | dump [--out FILE]] [--data-dir PATH]
zigbase migrate-db --from SQLITE_PATH --to POSTGRES_URL [--force]
zigbase schema [dump [--json] [--out FILE] | apply FILE [--dry-run] [--allow-destructive] [--prune]] [--data-dir PATH]
zigbase openapi [--data-dir PATH] [--out FILE] [--title TEXT] [--api-version VERSION] [--server URL]
zigbase import [--collection NAME [--upsert-key FIELD] <file.ndjson> | --manifest FILE]
               [--legacy-hashes ALG] [--dry-run] [--continue-on-error] [--error-log FILE]
               [--progress N] [--batch-size N] [--preserve-timestamps] [--json] [--data-dir PATH]
zigbase superuser create --email E --password P [--data-dir PATH]
zigbase typegen [--data-dir PATH | --url URL] [--out FILE] [--lang L] [--check] [...]
zigbase rewrap [--data-dir PATH] [--dry-run]
zigbase doctor [--production] [--json] [--data-dir PATH]
zigbase vapid-keygen
zigbase explain-code [CODE] [--json]
zigbase version
zigbase help
```

`migrate` defaults to applying pending migrations; `status` reports the ledger without
changing anything, `rollback [N]` reverses the last N applied, and `dump` writes the live
schema as a canonical migration.

`serve --background` detaches and exits 0 only once the server answers; `serve
stop|status|logs` manage that session; `serve --ephemeral` starts a throwaway server on a
temp dir and a free port, printing one JSON object; `doctor` runs preflight checks and exits
`1` on any error, `2` on warnings only, `0` when fully clean. See [docs/serve.md](docs/serve.md).

`migrate-db` copies an existing SQLite database into a
PostgreSQL target. `typegen` emits a typed SDK for a running (`--url`) or offline
(`--data-dir`) server — `--lang` picks the target language, `--check` verifies the output is
up to date without writing (run `zigbase typegen --help` for the full flag set). `init`,
`agents-md`, and `typegen` are pure dev-time surfaces (scaffolding + codegen) compiled in by
default (`-Ddev-tools`, on) — every binary we publish has them; `-Ddev-tools=false` is an
opt-out for your own custom build that never needs them. `rewrap`
rotates field-encryption keys (`--dry-run` reports without rewriting), and `vapid-keygen`
prints a fresh Web Push VAPID keypair. `explain-code` looks up a frozen API error code
(the `code` field in every `{status,code,message,data}` error response) with no args to
list them all, or `zigbase explain-code <CODE>` (`--json` for machine-readable output) for
one. See [docs/api.md → Conventions](docs/api.md#conventions). `doctor` runs nine preflight
checks over a deployment (JWT-secret persistence, `@public` rules, cookie/host/proxy/mailer
config, migrations, data-dir writability, legacy password hashes) and exits `0`/`2`/`1`
clean/warnings-only/error so
it can gate a deploy (`--production` escalates the checks that are only risky, not always
wrong, in dev); `--json` emits NDJSON findings. See [docs/serve.md](docs/serve.md).

`import` bulk-loads NDJSON records **offline (no running server)** through the record
engine — validation, defaults, the `.encrypted` envelope, and auth password hashing all
apply — with optional `--upsert-key` idempotency and source-id preservation. See
[docs/framework.md](docs/framework.md) → "Offline bulk import".

`schema` is the declarative half: `schema dump` writes the canonical JSON collection
model and `schema apply` executes the difference between a document and the live schema
through the same path the REST collections API uses — refusing the whole document, before
writing anything, if any access rule in it fails to parse. `schema check-rules` lints access-rule
expressions — which nothing validates when they are *written*, so a malformed rule otherwise
ships silently and fails closed (500) on the first request — through the real rule pipeline,
emitting `doctor`-shaped NDJSON findings and exiting `0`/`2`/`1` clean/warnings-only/error.
Given a document it is a **syntax**-depth check; run against a data dir it is **full** depth
and also resolves field and relation names. Together with `import --manifest` and
`import --legacy-hashes` they are the machinery behind
[migrating an existing backend to ZigBase](docs/migration-tools.md). PocketBase 0.39.11 has a
dedicated, decision-driven workflow in [docs/migrate-pocketbase.md](docs/migrate-pocketbase.md).
Complete Rails applications use the coordinating
[full-stack Rails workflow](docs/migrate-rails-fullstack.md), which composes the Rails backend and
Zigapagos presentation adapters through a versioned, reconciled route map.

`openapi` inspects that live collection model without starting or mutating the server and emits
OpenAPI 3.1.2 JSON. A framework binary also includes its comptime typed and untyped routes; the
stock binary is collection-only. See [docs/openapi.md](docs/openapi.md).

Running `zigbase` with no recognised command prints usage.

## Configuration

Configuration resolves in order of increasing precedence: built-in defaults, then
environment variables, then `serve` command-line flags (where a flag exists).

| Env var | Flag | Default | Purpose |
|---|---|---|---|
| `ZIGBASE_HTTP_HOST` | `--http-host` | `127.0.0.1` | bind address (loopback by default; set `0.0.0.0` for all interfaces) |
| `ZIGBASE_HTTP_PORT` | `--http-port` | `8090` | listen port |
| `ZIGBASE_DATA_DIR` | `--data-dir` | `./zb_data` | data directory (holds `data.db`, `storage/`, and `.jwt_secret`) |
| `ZIGBASE_DB_URL` | — | `""` (embedded SQLite) | database backend selector: a `postgres://…` URL routes storage to Postgres (requires a `-Dpostgres` build); unset/empty = SQLite in the data dir |
| `ZIGBASE_JWT_SECRET` | — | _auto-generated_ | token signing secret (≥32 bytes). Unset → a random secret is generated + persisted at `<data-dir>/.jwt_secret` (0600); a shorter provided value is refused |
| `ZIGBASE_FIELD_KEY` | — | `""` (unset) | key for at-rest field encryption (`.encrypted` fields). Never auto-generated/persisted/logged; the server **refuses to start** if any collection declares an encrypted field while this is empty. See [docs/fields.md](docs/fields.md) |
| `ZIGBASE_FIELD_KEY_GENERATION` | — | `1` | generation of the primary (write) field-encryption key — the envelope version stamped on writes (`v<N>:`). Bump to rotate, then run `zigbase rewrap` |
| `ZIGBASE_FIELD_KEY_V<n>` | — | _unset_ | older read-only key for generation `<n>`, needed to decrypt existing `v<n>:` data after a key rotation |
| `ZIGBASE_FIELD_CRYPTO` | — | `real` | **dev builds only** (`-Ddev-mode`, on by default in Debug): set `fake` to store `.encrypted` fields as readable `fake:<key>:<value>` instead of AES-GCM — useful for eyeballing values while debugging. Compiled out of release binaries; never read there. See [docs/fields.md](docs/fields.md) |
| `ZIGBASE_COOKIE_SECURE` | `--insecure-cookies` (sets `false`) | `true` | mark auth cookies `Secure`. On by default; opt out for plain-HTTP local dev |
| `ZIGBASE_TRUST_PROXY` | `--trust-proxy` (sets `true`) | `false` | trust `X-Forwarded-For`/`X-Real-IP` for client-IP / rate-limit keying (set only behind a trusted reverse proxy) |
| `ZIGBASE_SERVE_BACKGROUND` | — | _unset_ | `1` forces `serve` to run in the background; any other value disables the automatic backgrounding that a detected AI-agent environment would otherwise trigger. See [docs/serve.md](docs/serve.md) |
| `ZIGBASE_AUTH_TOKEN_TTL` | — | `1209600` (14 days) | auth token lifetime, seconds |
| `ZIGBASE_VERIFICATION_TTL` | — | `604800` (7 days) | email-verification token lifetime, seconds |
| `ZIGBASE_PASSWORD_RESET_TTL` | — | `3600` (1 hour) | password-reset token lifetime, seconds |
| `ZIGBASE_REALTIME_ORIGINS` | `--realtime-origins` | `""` (deny cross-origin) | CSV of allowed WebSocket/SSE `Origin`s — the gate applies to both transports. Empty denies cross-origin browser upgrades |
| `ZIGBASE_SSE_HEARTBEAT_SECONDS` | `--sse-heartbeat-seconds` | `0` (inherit 40s listener timeout) | SSE heartbeat (`: ping`) interval, 1–255 seconds |
| `ZIGBASE_REALTIME_OUTBOUND_HWM` | `--realtime-outbound-hwm` | `1024` (frames) | slow-consumer outbound high-water-mark: max queued outbound frames per realtime (WS/SSE) connection before the server disconnects the peer. `0` disables the bound |
| `ZIGBASE_MAX_UPLOAD_SIZE` | — | `52428800` (50 MiB) | max request body size, bytes |
| `ZIGBASE_FILE_TOKEN_TTL` | — | `120` (2 min) | file-access token lifetime, seconds |
| `ZIGBASE_STATIC_CACHE_CONTROL` | `--static-cache-control` | `max-age=3600` (facil.io stock) | `Cache-Control` value for static responses (embedded + dir); flag wins over env, both win over the comptime `.static_cache_control` default |
| `ZIGBASE_SENTRY_DSN` | — | `""` (log to stderr) | set to enable Sentry error reporting |
| `ZIGBASE_RATE_LIMIT_MAX` | — | `10` | max sensitive-auth attempts per window per client; `0` disables rate limiting |
| `ZIGBASE_RATE_LIMIT_WINDOW` | — | `60` | rate-limit window length, seconds |
| `ZIGBASE_OAUTH_STATE_SERVER` | — | `true` | server-side OAuth `state` (CSRF) store is **on by default**; set `false` to opt out (client-driven state only — PKCE still required) |
| `ZIGBASE_OAUTH_STATE_TTL` | — | `600` (10 min) | server-side OAuth `state` lifetime, seconds |
| `ZIGBASE_PUBLIC_URL` | — | `""` | public base URL used to build user-facing links (magic-link sign-in emails). Unset → magic-link emails contain the raw token instead of a clickable URL |
| `ZIGBASE_UNSUBSCRIBE_BASE_URL` | — | `""` (off) | public base URL for the RFC 8058 one-click unsubscribe endpoint. Empty disables the feature (routes 404 and no `List-Unsubscribe` header is added); overrides the comptime `.mail` key |
| `ZIGBASE_SMTP_HOST` | — | `""` (use LogMailer) | SMTP server host; set to deliver verify/reset email instead of logging |
| `ZIGBASE_SMTP_PORT` | — | `25` | SMTP server port |
| `ZIGBASE_SMTP_USERNAME` | — | `""` | SMTP username; non-empty enables `AUTH LOGIN` |
| `ZIGBASE_SMTP_PASSWORD` | — | `""` | SMTP password |
| `ZIGBASE_SMTP_FROM` | — | `noreply@zigbase.dev` | envelope + `From:` address |
| `ZIGBASE_SMTP_TLS` | — | `auto` | transport security: `none` / `starttls` / `implicit` / `auto` (auto: 465→implicit, 587→starttls, else→none) |
| `ZIGBASE_SMTP_INSECURE` | — | `false` | skip TLS cert verification (self-signed relays only) |
| `ZIGBASE_SENDMAIL_COMMAND` | — | `""` | deliver mail by piping RFC-822 to this command (e.g. `sendmail -t`) instead of SMTP; takes precedence over `ZIGBASE_SMTP_HOST` |
| `ZIGBASE_TWILIO_ACCOUNT_SID` | — | `""` (log SMS) | Twilio Account SID; set (with token + from) to deliver `ctx.sms()` messages via Twilio instead of logging |
| `ZIGBASE_TWILIO_AUTH_TOKEN` | — | `""` | Twilio auth token (used as the HTTP Basic-auth password) |
| `ZIGBASE_TWILIO_FROM` | — | `""` | Twilio sender number in E.164 (e.g. `+15551234567`) |
| `ZIGBASE_S3_BUCKET` | — | `""` (off) | **Opt-in.** Non-empty selects the S3-compatible storage backend instead of local disk. Only honored in a binary built with `-Ds3=true`; ignored otherwise |
| `ZIGBASE_S3_REGION` | — | `us-east-1` | AWS region (SigV4 signing + default endpoint) |
| `ZIGBASE_S3_ENDPOINT` | — | `""` | `""` → `https://s3.<region>.amazonaws.com`; set for MinIO/R2/other S3-compatible endpoints |
| `ZIGBASE_S3_ACCESS_KEY_ID` | — | `""` | SigV4 access key id (required with `ZIGBASE_S3_BUCKET`) |
| `ZIGBASE_S3_SECRET_ACCESS_KEY` | — | `""` | SigV4 secret access key (required with `ZIGBASE_S3_BUCKET`) |
| `ZIGBASE_S3_FORCE_PATH_STYLE` | — | _auto_ | `true`/`1` forces path-style addressing; unset auto-selects path-style when `ZIGBASE_S3_ENDPOINT` is set, virtual-hosted otherwise |
| `ZIGBASE_S3_KEY_PREFIX` | — | `""` | prefix prepended to every object key — namespace multiple apps in one bucket |
| `ZIGBASE_S3_CACHE_DIR` | — | `""` | `""` → `<data-dir>/storage_cache`; local spool-cache directory downloads materialize through |
| `ZIGBASE_S3_CACHE_MAX_BYTES` | — | `1073741824` (1 GiB) | spool-cache size cap; eviction reclaims down to a 3/4 low-water mark |
| `ZIGBASE_VAPID_PUBLIC_KEY` | — | `""` | Web Push VAPID public key (base64url) for `ctx.push()`; also the browser `applicationServerKey`. Generate a pair with `zigbase vapid-keygen` |
| `ZIGBASE_VAPID_PRIVATE_KEY` | — | `""` | Web Push VAPID private key (base64url) — **secret**. Both keys unset → `ctx.push()` is a no-op |
| `ZIGBASE_LOG_FORMAT` | `--log-format` | `text` | log encoding: `text` or `json` (one JSON object per line on stderr) |
| `ZIGBASE_LOG_LEVEL` | `--log-level` | `info` | minimum severity: `debug`, `info`, `warn`, `error` |
| `ZIGBASE_LOG_REQUESTS` | `--no-request-log` | `true` | emit a per-request access line (method, path, status, duration) |

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

**Reporting a vulnerability:** please report privately via
[the Security tab](https://github.com/valthon/zigbase/security/advisories/new), never in a
public issue. [SECURITY.md](SECURITY.md) covers supported versions, what to include, what to
expect, and what is explicitly out of scope. The full threat model and every past finding
with its fix are in [docs/security-audit.md](docs/security-audit.md).

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
  blog/                    basic packaging proof (hook, custom route, cron job, --serve-static Zigapagos frontend)
  golfsim/                 a realistic app built on ZigBase (hooks, routes, cron, comptime .dir static frontend)
  plugins/                 advanced framework features (custom plugins, comptime schema, typed migrations, pools, embedded static frontend)
```

## Documentation

- [docs/app-genesis.md](docs/app-genesis.md) — turn an idea into a rules-first design: trust boundaries, schema shape, relations, hooks/routes, pagination, realtime, and test placement
- [docs/tutorial.md](docs/tutorial.md) — **start here**: build an app on ZigBase, end to end (provision → rules → signup → records + file upload → custom route → cron)
- [docs/fields.md](docs/fields.md) — field-type & options catalog (all 12 types, defaults, validation rules)
- [docs/recipes.md](docs/recipes.md) — task recipes: ship a frontend in the binary, schema provisioning (curl), signup, owner/relation access rules, hooks, custom routes, DB access in cron
- [docs/api.md](docs/api.md) — HTTP API reference (collections, records, query, rules, auth, oauth2, realtime, files, static files, admin)
- [docs/openapi.md](docs/openapi.md) — deterministic OpenAPI export for collection CRUD and framework consumer routes
- [docs/zigapagos-pairing.md](docs/zigapagos-pairing.md) — one-origin Zigapagos + ZigBase architecture, dev loop, layered tests, and deployment choices
- [docs/framework.md](docs/framework.md) — embedding ZigBase: hooks, routes, jobs, static-file modes
- [docs/serve.md](docs/serve.md) — running the server: background sessions, `stop`/`status`/`logs`, ephemeral instances, and the `doctor` preflight
- [docs/deployment.md](docs/deployment.md) — systemd, Docker Compose, reverse-proxy TLS, Fly, Railway, backups, upgrades, and rollback
- [docs/agent-evals.md](docs/agent-evals.md) — run the provider-neutral Genesis agent evaluation and inspect the first verified three-run, zero-intervention flagship evidence
- [docs/migrate-express.md](docs/migrate-express.md) — discovery-driven Express re-platforming with durable endpoint decisions, deterministic import, parity replay, and rehearsed cutover
- [docs/migrate-laravel.md](docs/migrate-laravel.md) and [docs/migrate-go.md](docs/migrate-go.md) — source-specific Laravel and Go migration workflows on the same evidence-first skeleton
- [docs/migrate-rails-api.md](docs/migrate-rails-api.md) — Rails API-only re-platforming with an observed-metadata inventory, the `tools/rails/rails2zb.py` converter, deterministic extraction, and an explicit backend-only scope gate
- [docs/migrate-rails-fullstack.md](docs/migrate-rails-fullstack.md) — complete Rails-to-ZigBase + Zigapagos migration with versioned handoffs, a reconciled route map, backend/browser parity, and rehearsed cutover
- [docs/typescript-sdk.md](docs/typescript-sdk.md) — the official `@zigbase/client` TypeScript SDK: auth, records, offset + cursor pagination, files, realtime + live store
- [docs/dart-sdk.md](docs/dart-sdk.md) — the official `zigbase_client` Dart SDK: auth, records, offset + cursor pagination, files, and realtime, for the Dart VM, Flutter, and Flutter web
- [docs/python-sdk.md](docs/python-sdk.md) — the official `zigbase` Python SDK: sync and async clients for auth, records, offset + cursor pagination, and files
- [docs/kotlin-sdk.md](docs/kotlin-sdk.md) — the official Kotlin SDK: a coroutine-first `ZigbaseClient` for auth, records, offset + cursor pagination, and files
- [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) — current caveats
- [CHANGELOG.md](CHANGELOG.md) — release history
- [CONTRIBUTING.md](CONTRIBUTING.md) — development setup, the two test suites, the quality bar, and how to open a PR
- [SECURITY.md](SECURITY.md) — supported versions and how to report a vulnerability

## Contributing

Contributions are welcome — bug reports with a real reproduction, docs fixes, and focused PRs
especially. Start with **[CONTRIBUTING.md](CONTRIBUTING.md)**: it covers the pinned toolchain,
the **two** test suites (a green `zig build test` does *not* imply a green browser suite), the
[`NO_SLOP.md`](NO_SLOP.md) quality bar, changelog fragments, and the docs/examples sync rules.

For anything non-trivial, open an issue and get agreement on the approach before writing the
code. AI-assisted contributions are welcome and are judged on the same terms as any other code
— see [CONTRIBUTING.md → AI-assisted contributions](CONTRIBUTING.md#ai-assisted-contributions).

Everyone participating is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Changelog

Don't edit `CHANGELOG.md` directly. For every recorded change, add a small fragment file
`changelog.d/<slug>.md` whose body is one or more `### <Section>` headings (each with
bullet lines) — a single fragment may populate multiple sections. Recognized sections, in
emit order: **Breaking, Features, Fixes, Changed, Performance, Deprecated, Removed,
Security, Internal**. The changelog is consumer-facing, so the first eight are for
**user-visible** changes; **Internal** (rendered last) is for contributor-facing changes
with no consumer impact (build/CI, tests, refactors, tooling). Rule of thumb: *would a user
notice → a consumer section; only contributors notice → Internal; nobody needs it recorded
→ no fragment.* See [changelog.d/README.md](changelog.d/README.md). Fragments mean parallel
PRs never conflict on the shared changelog; at release time `scripts/assemble-changelog.sh`
aggregates them per section into a new version block in `CHANGELOG.md` (and its `site/`
mirror) and deletes them.

## License

Apache-2.0.
