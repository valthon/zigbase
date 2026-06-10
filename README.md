# ZigBase

ZigBase is a single-binary, PocketBase-inspired (but **not** API-compatible) backend in
**Zig 0.16**. It bundles a collections + schema engine, a typed records query API
(filter / sort / expand), per-collection access rules, authentication (argon2id password
plus OAuth2 with PKCE), realtime updates over WebSocket, local file storage, and an
embedded admin UI at `/_/` — all in one statically-linked executable backed by SQLite.
It is also an **embeddable Zig framework**: import it as a library and extend the server
with comptime record hooks, custom HTTP routes, and scheduled jobs.

`v0.1.0 — early release` · `License: Apache-2.0` · see [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)

## Quickstart (run the binary)

```sh
mise install                                    # installs Zig 0.16.0 (pinned in mise.toml)
zig build                                        # -> zig-out/bin/zigbase   (or: mise exec zig@0.16.0 -- zig build)
./zig-out/bin/zigbase superuser create --email you@example.com --password "<a strong password>" --data-dir ./zb_data
ZIGBASE_JWT_SECRET="$(head -c 32 /dev/urandom | base64)" ./zig-out/bin/zigbase serve --data-dir ./zb_data
# open http://127.0.0.1:8090/_/  (admin UI) and sign in as the superuser
curl http://127.0.0.1:8090/api/health           # {"status":"ok"}
```

The default bind is `0.0.0.0:8090`. Your `zig` must be 0.16.0 — either activate mise
(`eval "$(mise activate bash)"`) or prefix commands with `mise exec zig@0.16.0 --`.

## Features

- **Collections & schema** — define collections with typed fields; schema migrations run on startup.
- **Records & query API** — typed CRUD with `filter`, `sort`, and `expand` on relations. → [docs/api.md](docs/api.md)
- **Access rules** — per-collection list / view / create / update / delete rules. → [docs/api.md](docs/api.md)
- **Auth** — argon2id password auth, JWT tokens, verification and password-reset flows. → [docs/api.md](docs/api.md)
- **OAuth2** — Authorization-Code + PKCE provider login and account linking. → [docs/api.md](docs/api.md)
- **Realtime** — subscribe to record changes over WebSocket. → [docs/api.md](docs/api.md)
- **Files** — local file storage with serving and short-lived file-access tokens. → [docs/api.md](docs/api.md)
- **Admin UI** — embedded single-page app served at `/_/`. → [docs/api.md](docs/api.md)
- **Framework** — comptime record hooks, custom routes, and scheduled jobs. → [docs/framework.md](docs/framework.md)

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
commands as the stock server. See [docs/framework.md](docs/framework.md) and the worked
example in [examples/blog/](examples/blog/).

## CLI

```
zigbase serve [--http-host H] [--http-port N] [--data-dir PATH]
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

> Note: verification and password-reset tokens are currently **logged**, not emailed —
> there is no built-in mail delivery. See [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).

## Security

Set `ZIGBASE_JWT_SECRET` to a strong, random value in production. The server **refuses
to start** when the secret is left at its insecure default and `ZIGBASE_COOKIE_SECURE=true`;
with the default secret and `cookie_secure` off, it logs a warning instead. An empty
`ZIGBASE_REALTIME_ORIGINS` allows any WebSocket origin (fine for development, lock it down
in production).

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
  blog/                    worked framework example (hook, custom route, cron job)
```

## Documentation

- [docs/tutorial.md](docs/tutorial.md) — **start here**: build an app on ZigBase, end to end (provision → rules → signup → records + file upload → custom route → cron)
- [docs/fields.md](docs/fields.md) — field-type & options catalog (all 12 types, defaults, validation rules)
- [docs/recipes.md](docs/recipes.md) — task recipes: schema provisioning (curl), signup, owner/relation access rules, hooks, custom routes, DB access in cron
- [docs/api.md](docs/api.md) — HTTP API reference (collections, records, query, rules, auth, oauth2, realtime, files, admin)
- [docs/framework.md](docs/framework.md) — embedding ZigBase: hooks, routes, jobs
- [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) — current caveats
- [CHANGELOG.md](CHANGELOG.md) — release history

## License

Apache-2.0.
