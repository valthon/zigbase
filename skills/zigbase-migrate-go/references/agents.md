# ZigBase for coding agents

> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/agents> — the site is the canonical reading experience.

Start here, then load one or two of the linked guides. The full corpus is
~200k tokens; you almost never need it.

## What ZigBase is

A single binary: REST API, WebSocket realtime, file storage, argon2id + JWT
auth, OAuth2, an admin UI at `/_/`, and an embedded SQLite database (Postgres
optionally). Linux and macOS; Windows is served by the Docker image.

You can use it two ways, and the answer changes which docs matter:

| Shape | You write | Read next |
| --- | --- | --- |
| **Backend in a box** | No Zig. Define collections over REST or in the admin UI, talk to it with an SDK. | [api.md](https://github.com/valthon/zigbase/blob/main/docs/api.md), [fields.md](https://github.com/valthon/zigbase/blob/main/docs/fields.md), your SDK guide |
| **Zig framework** | A Zig package that embeds ZigBase and adds a comptime schema, hooks, routes, and jobs. | [framework.md](https://github.com/valthon/zigbase/blob/main/docs/framework.md), [testing.md](https://github.com/valthon/zigbase/blob/main/docs/testing.md) |

## Get something running

```sh
npx zigbase init            # backend in a box (docker-compose + schema + AGENTS.md)
npx zigbase init --framework # a Zig package embedding ZigBase
```

`init` never overwrites an existing file — it reports skips and exits 0, so it
is safe to run in a directory that already has work in it. It also writes an
`AGENTS.md` full of the traps below; `zigbase agents-md` writes it for a project
that already exists — it never overwrites, so delete the old one first or diff
against `zigbase agents-md --stdout`.

`init`, `agents-md`, and `typegen` are compiled in by default (`-Ddev-tools`); a
custom-built binary may omit them (`-Ddev-tools=false`) — the official release,
Docker image, and npm packages always have them.

## The five things that bite

1. **Access rules default to LOCKED.** A `null` or `""` rule means *superusers
   only*, not *public*. `"@public"` is the only allow-all value; anything else
   is a filter expression evaluated per record. Rule parse errors fail closed
   (500). Every `@public` rule is logged as a warning at startup — read them.
2. **Plain-HTTP local dev needs `--insecure-cookies`.** Auth cookies are
   `Secure` by default, so a browser on `http://127.0.0.1` silently refuses to
   store them and the admin UI just bounces back to the login form.
3. **`serve` binds `127.0.0.1`.** Inside a container that means unreachable —
   `--http-host 0.0.0.0` there, and only there.
4. **One error envelope.** Every endpoint — built-in and your own typed
   routes — answers `{"status": 404, "code": "not_found", "message": "…",
   "data": {}}`. `code` is a frozen machine-readable string: branch on it, not
   on `message` (human text, not contract). Per-field validation failures live
   under `data.<field>.{code,message}`. `zigbase explain-code CODE` resolves a
   code to its meaning.
5. **The data dir is a credential store.** It holds the database, uploads, and
   `.jwt_secret` (generated on first run). Losing it invalidates every issued
   token. Never commit it; in Docker, mount it.

## Shapes you can rely on

- Every list endpoint returns an object, never a bare array:
  `{"items": [...], "page": 1, "perPage": 30, "totalItems": n, "totalPages": n}`.
  Cursor pagination uses `cursor`/`limit` and answers `nextCursor`/`hasNext`.
- A successful side effect with no body is **204**.
- URL segments are dash-case.
- Realtime re-applies each collection's `view` rule per record per subscriber,
  so a subscriber does not necessarily see every write.
- `GET /api/meta` is a public, unauthenticated capability probe: `capabilities`
  (booleans — `oauth2`, `postgres`, `collectionsFrozen`, …), `endpoints`, and
  `limits.maxUploadSize` for the running build.

## The CLI

```
zigbase serve [--http-host H] [--http-port N] [--data-dir PATH] [--insecure-cookies]
              [--background] [--ephemeral]
zigbase serve stop|status|logs [--data-dir PATH]   # manage a --background session
zigbase doctor [--production] [--json] [--data-dir PATH]
zigbase migrate [status|rollback N|dump]
zigbase schema dump [--out FILE] [--data-dir PATH]
zigbase schema apply FILE [--dry-run] [--allow-destructive] [--prune]
zigbase openapi [--data-dir PATH] [--out FILE] [--title TEXT] [--api-version VERSION] [--server URL]
zigbase superuser create --email … --password …
zigbase explain-code [CODE] [--json]
zigbase init [--box|--framework] [--dir PATH] [--name NAME]
zigbase agents-md [--box|--framework] [--dir PATH] [--stdout]
zigbase version
zigbase help                # and `zigbase <command> --help`
```

In a detected AI-agent environment, `serve` backgrounds itself by default —
use `serve status`/`serve logs`/`serve stop` to manage that session instead of
waiting on a foreground process. `zigbase help` is the authoritative list —
trust it over any document, including this one.

## Which guide to load

| If you are… | Load |
| --- | --- |
| turning an idea into an app design | [app-genesis.md](https://github.com/valthon/zigbase/blob/main/docs/app-genesis.md) |
| implementing collections and fields | [fields.md](https://github.com/valthon/zigbase/blob/main/docs/fields.md), [recipes.md](https://github.com/valthon/zigbase/blob/main/docs/recipes.md) |
| calling the API | [api.md](https://github.com/valthon/zigbase/blob/main/docs/api.md) |
| generating or reviewing an HTTP contract | [openapi.md](https://github.com/valthon/zigbase/blob/main/docs/openapi.md) |
| writing Zig hooks, routes, jobs, or a comptime schema | [framework.md](https://github.com/valthon/zigbase/blob/main/docs/framework.md) |
| writing tests | [testing.md](https://github.com/valthon/zigbase/blob/main/docs/testing.md) |
| pairing a Zigapagos frontend with a framework app | [zigapagos-pairing.md](https://github.com/valthon/zigbase/blob/main/docs/zigapagos-pairing.md) |
| wiring a frontend | [typescript-sdk.md](https://github.com/valthon/zigbase/blob/main/docs/typescript-sdk.md) |
| calling from Python / Dart / Kotlin | [python-sdk.md](https://github.com/valthon/zigbase/blob/main/docs/python-sdk.md), [dart-sdk.md](https://github.com/valthon/zigbase/blob/main/docs/dart-sdk.md), [kotlin-sdk.md](https://github.com/valthon/zigbase/blob/main/docs/kotlin-sdk.md) |
| deploying | [deployment.md](https://github.com/valthon/zigbase/blob/main/docs/deployment.md), [docker.md](https://github.com/valthon/zigbase/blob/main/docs/docker.md) |
| evaluating an app-building agent | [agent-evals.md](https://github.com/valthon/zigbase/blob/main/docs/agent-evals.md) |
| migrating PocketBase 0.39.11 | [migrate-pocketbase.md](https://github.com/valthon/zigbase/blob/main/docs/migrate-pocketbase.md) |
| re-platforming a Node.js/Express service | [migrate-express.md](https://github.com/valthon/zigbase/blob/main/docs/migrate-express.md) |
| re-platforming a Laravel application | [migrate-laravel.md](https://github.com/valthon/zigbase/blob/main/docs/migrate-laravel.md) |
| re-platforming a Go web service | [migrate-go.md](https://github.com/valthon/zigbase/blob/main/docs/migrate-go.md) |
| re-platforming a Rails API-only backend | [migrate-rails-api.md](https://github.com/valthon/zigbase/blob/main/docs/migrate-rails-api.md) |
| doing per-row authorization | [abilities.md](https://github.com/valthon/zigbase/blob/main/docs/abilities.md), [tenancy.md](https://github.com/valthon/zigbase/blob/main/docs/tenancy.md) |
| adding search | [search.md](https://github.com/valthon/zigbase/blob/main/docs/search.md) |
| sending mail, or running background work | [email.md](https://github.com/valthon/zigbase/blob/main/docs/email.md), [jobs-and-webhooks.md](https://github.com/valthon/zigbase/blob/main/docs/jobs-and-webhooks.md) |
| hitting something that does not work | [known-limitations.md](https://github.com/valthon/zigbase/blob/main/KNOWN_LIMITATIONS.md) |

Machine-readable indexes: <https://valthon.github.io/zigbase/llms.txt> and
<https://valthon.github.io/zigbase/docs-index.json>.

## Conventions if you are contributing to ZigBase itself

Different job, different rules — those live in the repository's `CLAUDE.md` and
`CONTRIBUTING.md`. The short version: changelog entries go in `changelog.d/`
fragments and never in `CHANGELOG.md`; published docs under
`site/src/content/docs/` are generated and must never be hand-edited; and a
green `zig build test` does not imply a green browser suite.
