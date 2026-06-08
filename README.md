# ZigBase

A PocketBase-inspired backend-as-a-service written in **Zig 0.16**, shipped as a single
static binary with an embedded SQLite database.

This is the **Foundation** sub-project: a running HTTP server backed by a WAL-mode SQLite
connection pool, a config/CLI layer, a JSON error envelope, and a `GET /api/health`
endpoint. Collections, the REST CRUD API, auth, realtime, file storage, and the admin UI
are built in subsequent sub-projects.

See the design and roadmap in
[`docs/superpowers/specs/2026-06-08-zigbase-architecture-design.md`](docs/superpowers/specs/2026-06-08-zigbase-architecture-design.md).

## Requirements

- [mise](https://mise.jdx.dev/) (pins the Zig toolchain via `mise.toml`)
- Zig **0.16.0** — `mise install` will fetch it

All build commands use the pinned toolchain. If `zig version` in your shell isn't `0.16.0`,
either activate mise (`eval "$(mise activate bash)"`) or prefix commands with
`mise exec zig@0.16.0 --`.

## Build, test, run

```sh
mise install                 # install Zig 0.16.0
zig build                    # -> zig-out/bin/zigbase
zig build test               # run the unit test suite
./zig-out/bin/zigbase serve --http-port 8090 --data-dir ./zb_data
```

Then, in another shell:

```sh
curl http://127.0.0.1:8090/api/health
# {"status":"ok"}
```

You can also run via the build system: `zig build run -- serve --http-port 8090`.

## CLI

```
zigbase serve [--http-host H] [--http-port N] [--data-dir PATH]
zigbase help
```

Running `zigbase` with no arguments prints usage.

## Configuration

Configuration resolves in order of increasing precedence: built-in defaults, then
environment variables, then `serve` command-line flags.

| Env var | Flag | Default | Purpose |
|---|---|---|---|
| `ZIGBASE_HTTP_HOST` | `--http-host` | `0.0.0.0` | bind address |
| `ZIGBASE_HTTP_PORT` | `--http-port` | `8090` | listen port |
| `ZIGBASE_DATA_DIR` | `--data-dir` | `./zb_data` | data directory (holds `data.db`) |
| `ZIGBASE_JWT_SECRET` | — | `dev-insecure-secret-change-me` | token signing secret (used by later auth work) |

## Project layout

```
build.zig, build.zig.zon   build graph; vendors SQLite, depends on zap
vendor/sqlite/             vendored SQLite amalgamation (3.53.2)
src/
  main.zig                 entry point; CLI dispatch; serve wiring
  c.zig                    @cImport of sqlite3.h
  db.zig                   Db / Stmt / Pool (WAL, mutex writer + read connections)
  config.zig               Config + env-overridable loader
  cli.zig                  argv parser
  http.zig                 RequestCtx / Response / Method / Handler types
  server.zig               thin zap -> pure-handler adapter
  api/error.zig            ApiError + JSON error envelope
  api/health.zig           GET /api/health handler
```

HTTP handlers are pure functions `(*RequestCtx) -> Response` and are unit-tested in
isolation; `server.zig` is the only module that knows about zap.

## Tech

- HTTP: [zap](https://github.com/zigzap/zap) (facil.io)
- Storage: SQLite (vendored amalgamation, WAL mode), accessed via C interop
- JSON: `std.json`
