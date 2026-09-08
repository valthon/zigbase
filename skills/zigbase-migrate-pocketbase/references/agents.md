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
zigbase serve stop|status|wait|logs [--data-dir PATH]   # manage a tracked session
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

## Machine-readable CLI discovery

Run `zigbase capabilities --json` before choosing an inspection command. It returns
one JSON object with `protocol_version: 1` and a bounded `operations` catalog.
Each entry has a stable `id`, an `argv` array (arguments after the executable,
not a shell command), `output` format, `effect`, `requires_database`, and `notes`.
Consumers should reject unsupported protocol versions and ignore unknown fields.
The catalog covers selected development operations, not every CLI command or API route.

Discovery itself does not load or validate deployment settings, opens no database,
and starts no server. CLI logging initialization still reads logging preferences.
It is compiled out with `-Ddev-tools=false`; invoking it then exits
nonzero with rebuild guidance. It does not execute the advertised operations.

Do not treat every diagnostic command as read-only. `effect: "may_write"`
means an operation can create or modify supporting state: `doctor` probes
writability and may initialize a ledger, while schema dump and migration status
open the database pool. Use an isolated development database unless those effects
are authorized. `effect: "read_only"` describes the supplied argument vector;
adding output-file options can introduce writes. Commands requiring a database
may need `--data-dir`; they also honor their existing environment configuration.
Diagnostic/status commands can exit nonzero while emitting valid structured output.

For HTTP registration discovery without a database, use `zigbase routes --json`.
For request/response schemas and live collection metadata, use the advertised
OpenAPI operation. For migration previews and test selection, consult their
command documentation. Discovery does not execute operations or remediate issues.

### Required inputs and structured diagnostics

`zigbase capabilities [--json]` emits a single catalog with runnable `operations`
and a separate `input_operations` array. The `diagnostics` operation invokes the
structured `diagnostics` verb. There is no protocol-selection flag.

Only `operations[].argv` is directly runnable. An input operation's `argv_prefix`
is **not a complete invocation**: append each supplied `inputs[].flag` and value
as separate arguments, never concatenate shell commands or execute placeholders.
The `tune` descriptor identifies its required JSON file, schema version, 1 MiB
limit, scalar types/constraints, candidate bounds and optional nonnegative
`--as-of` timestamp. The captured `resources` object is intentionally not expanded
into a complete schema; its `capture_argv` obtains the real report. These are
bounded descriptors, **not JSON Schema**. Consult their canonical reference for
measurement semantics. Integer `minimum_decimal`/`maximum_decimal` bounds are
inclusive base-10 strings: parse them losslessly (for example with JavaScript
`BigInt`), not as floating-point numbers. They describe numeric JSON input fields,
not string-valued fields; serialize large input integers without rounding.
`forbidden_byte_ranges` contains objects with inclusive numeric `minimum` and
`maximum` byte values, applied to UTF-8 bytes (0–31 and 127 for labels).
Tune retains its existing output/error behavior.

`zigbase diagnostics [--json] [--production] [--data-dir PATH]` adapts existing
doctor checks into one JSON document (`protocol_version: 1`,
`scope: "development-diagnostics"`). JSON is the default. A completed run has
`status: "complete"`, `findings`, the unchanged doctor `summary`, and `exit_code`:
0 clean, 1 errors, 2 warnings only. Completed does not mean healthy. Existing
doctor NDJSON and frozen check identifiers/severities remain unchanged.

Argument, configuration or runtime failures instead have `status: "error"`,
`exit_code: 1`, and `failure: {phase, code, subject, expected}`. Codes are
`invalid_arguments`, `invalid_environment`, and `diagnostic_failed` respectively;
nullable subject/expected provide context without including supplied bad values.
An option after `--data-dir` is a missing value; prefix a path beginning with `-`
with `./` to pass it as a directory.
Findings' human messages are not stable identifiers and can include deployment
paths or collection names: treat diagnostic reports as deployment information.
Help is prose; disabled builds retain the existing nonzero stderr guidance, not
a JSON error envelope. Output-device failures and process termination cannot
guarantee a complete document.
Keep stdout separate from stderr: merging log output into the same stream is not
a JSON document contract. Diagnostics and capabilities respect the inherited
stdout file offset when redirected; they do not overwrite earlier file content.

The adapter is **not offline/read-only**: it loads deployment configuration,
probes filesystem writability, opens the database and may initialize a migration
ledger. Use an authorized isolated development data directory. Report memory
scales with the existing doctor's deployment findings; buffering the document
does not impose a global memory cap. The adapter and catalog compile out with
`-Ddev-tools=false`; ordinary doctor remains available.

### Offline compiled routes

`zigbase routes [--json]` emits one deterministic JSON object with
`protocol_version: 1`, `scope: "compiled-route-registrations"`, `items`,
`reserved_prefixes`, `coverage`, and `notes`. It shares the discovery command's
offline/no-database behavior and `-Ddev-tools` gate. `routes --help` documents its
arguments; server/deployment flags are not accepted.

Each item contains an uppercase `method`, router `path` (captures use `:name`),
`source` (`builtin`, `custom`, `realtime`, or `feature_state`), optional `name`,
and redacted declarative auth metadata. Built-ins come from this binary's actual
gated dispatch table, not a catalog of every feature ZigBase could support.
The configured feature-state path is included for GET and HEAD; remapping or
disabling it releases the old path. An admin-enabled build reports the `/_`
reserved prefix, not a fabricated list of admin endpoints.

`declared_access: null` means **unknown**, not public. For custom routes the
value is the framework's declared `public`, `authed`, or `superuser` level;
`authed_collection` adds the declared principal-collection constraint, and
`path_secret` describes only the submitted parameter/location/mismatch behavior.
Neither configured secret values nor KV/settings secret keys are exported.
**A public level with `path_secret` still requires the secret.** Built-in access
labels are supplied only where the engine already owns an explicit declaration.
Handlers, hooks, collection rules and deployment configuration can impose
additional checks or return unavailable; this inventory cannot authorize a request.

Entries preserve declaration order within each source. The first matching custom
route wins, so an earlier captured pattern can shadow a later literal. The array
is not a cross-source dispatch priority list. Static assets/rewrites, individual
admin endpoints and runtime authorization are explicitly excluded in `coverage`.
Use the **application's compiled binary**, not a stock ZigBase executable, when
inspecting its custom routes. Reject unsupported protocol versions and tolerate
unknown fields/source kinds when reading the inventory.

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
| replacing a complete Rails application | [migrate-rails-fullstack.md](https://github.com/valthon/zigbase/blob/main/docs/migrate-rails-fullstack.md) |
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
