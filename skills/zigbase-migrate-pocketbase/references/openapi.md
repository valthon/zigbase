# OpenAPI export

`zigbase openapi` writes a deterministic OpenAPI 3.1.2 JSON document for the API a ZigBase
binary can describe exactly: live non-system collection CRUD plus that binary's declared consumer
routes.

Use it to generate API clients, seed contract tests, review an agent-built backend, or compare a
migrated service's intended HTTP surface. The command does not start the server, run migrations,
provision the framework's comptime collections, or make application HTTP requests. SQLite export
is fully offline; PostgreSQL export connects only to the configured database URL so it can inspect
live collection metadata.

## Export a document

```sh
zigbase openapi --data-dir ./zb_data > openapi.json
zigbase openapi --data-dir ./zb_data --out generated/openapi.json
zigbase openapi --data-dir ./zb_data \
  --title "Acme API" --api-version 2026-08 \
  --server https://api.example.com --out generated/openapi.json
```

`--out` creates parent directories and atomically replaces an existing artifact. Without it, the
only stdout output is the JSON document. The output always ends with a newline.

The database must already exist. Export opens SQLite with read-only flags and fails instead of
creating a missing data directory or database. PostgreSQL export uses `ZIGBASE_DB_URL` when the
binary was built with `-Dpostgres=true`. The command reads collection metadata only; it never
reads or emits record rows.

The stock `zigbase` binary describes live collections. A framework binary built with
`zigbase.App(.{ .routes = ... })` additionally describes its own comptime routes:

```sh
zig build run -- openapi --data-dir ./zb_data --out openapi.json
```

Run the framework binary when custom routes matter. Running the stock binary against the same
data directory cannot discover handler types from another executable.

## Collection contract

Every non-system collection contributes these literal paths:

- `GET` and `POST /api/collections/<name>/records`;
- `GET`, `PATCH`, and `DELETE /api/collections/<name>/records/{id}`.

Record, create, update, and list components preserve field types and applicable length, pattern,
numeric, enum, selection-count, relation, file-size, and MIME constraints. Record schemas include
`id`, `created`, and `updated`. Auth create schemas include write-only `password` and
`passwordConfirm`. Engine-only credential columns such as `passwordHash` and `tokenKey` are never
exported. A user-defined hidden field remains visible to contract tooling as `writeOnly: true`.

List operations describe both offset (`page`, `perPage`) and cursor (`cursor`, `limit`) pagination,
plus filter, sort, search, vector, expand, and field-projection parameters. Responses use the real
ZigBase list envelopes and the canonical `{status, code, message, data}` error schema.

## Reading access metadata

Access rules are represented without pretending that every conditional rule has the same
credential requirement:

| ZigBase rule | OpenAPI representation |
| --- | --- |
| `@public` | `security: []`, `x-zigbase-access: "public"` |
| `null` or empty | bearer JWT security, `x-zigbase-access: "locked"` |
| any expression | no normative `security`, `x-zigbase-access: "conditional"`, exact `x-zigbase-rule` |

This makes intentional anonymous signup usable: an auth collection whose create rule is
`@public` exports its create operation as public. `doctor --production` separately reports that
reviewed choice as a warning, not an inescapable error. Keep the durable rationale in
`security/public-rules.json`; an OpenAPI document describes access but does not approve it.

## Consumer routes

Typed route inputs and outputs map recursively from Zig's supported route subset: booleans,
integers, floats, strings, enums, optionals, slices, structs, and `std.json.Value`. `:id` path
segments become `{id}` parameters. Top-level struct inputs on `GET` and `DELETE` become query
parameters; other non-void inputs become JSON request bodies. JSON outputs return `200`, while a
void typed output returns `204`.

Untyped handlers remain in the document with `x-zigbase-untyped: true`, but no response body is
invented. Public, authenticated, superuser, and collection-scoped authentication are explicit.
Path-secret routes include only the submitted parameter name, location, and mismatch behavior.
The configured secret and the key used to load it are not present in route metadata and cannot be
serialized.

## Deliberate coverage boundary

This first contract does not claim to describe the entire ZigBase server. Read the root
`x-zigbase-coverage` object before generating tests or clients:

```json
{
  "collections": true,
  "consumerRoutes": true,
  "admin": false,
  "realtime": false,
  "fileBytes": false,
  "allAuthMethods": false
}
```

`consumerRoutes` is `false` for a binary with no declared custom routes. Admin management,
WebSocket/SSE transports, file-byte endpoints, and every built-in auth-method endpoint remain in
the ordinary [API reference](api.md); their omission from this document is explicit, not a claim
that the running server lacks them.

## CI and agent workflow

Commit the generated file when downstream code or review depends on it, then regenerate and diff
it after schema or route changes:

```sh
zig build run -- openapi --data-dir ./zb_data --out contracts/openapi.json
git diff --exit-code -- contracts/openapi.json
```

An agent should treat an unexpected diff as a contract change requiring review. It should not
edit generated OpenAPI by hand, infer omitted endpoints, weaken locked access, or place secret
values in descriptions or extensions.
