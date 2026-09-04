# OpenAPI export

`zigbase openapi` writes a deterministic OpenAPI 3.1.2 JSON document for the API a ZigBase
binary can describe exactly: live non-system collection CRUD plus that binary's declared consumer
routes.

The root `x-zigbase-reserved-routes` array is derived from the binary's actual built-in server route
table and lists engine-owned method/path templates that dispatch before consumer routes. Optional
groups follow that application's compile-time gates, and a remapped public feature-state route is
included at its configured path for both `GET` and `HEAD`.
`x-zigbase-feature-public-route` records that configuration as the canonical path string, or JSON
`null` when the feature projection is disabled. Only the live mount is reserved for `GET` and
`HEAD`: remapping releases `/api/state`, and disabling the projection reserves no feature route,
so either configuration may reuse the old path for a consumer route.
A remap is a canonical fixed path and cannot use a router capture, the admin prefix, or overlap any
enabled built-in `GET`/`HEAD` route. `HEAD` returns the same status, content type, and representation
length as `GET` with no response-body bytes.
The companion `x-zigbase-reserved-prefixes` array describes engine-owned dispatch namespaces. An
admin-enabled binary exports `{"path":"/_","source":"admin"}`: the reservation covers `/_`
itself and every slash-delimited descendant such as `/_/health`, but not the near-miss `/__`.
The entry is absent when that binary compiles with `.admin = .disabled`.
The root `x-zigbase-gates` object exports every boolean compile-time server gate. Gates, reserved
routes, and reserved prefixes are co-generated from the same compiled server contract, so consumers
can use them directly instead of reconstructing engine namespaces. Consumers require the gates they
interpret to be present and boolean, reject non-boolean entries, and tolerate additional boolean
gates added under the same contract version.
`x-zigbase-builtin-operations` provides stable ids, access, and collection templates for standard
auth operations from the same server-owned entries used to assemble dispatch, and
`x-zigbase-contract-version` is the fixed exporter-format version (`"1"` for this shape). It is
independent of the application-controlled `info.version`, so consumers can reject metadata from an
unsupported exporter contract even when applications choose the same release label.

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
only stdout output is the JSON document. The output always ends with a newline. If `--api-version`
is omitted, `info.version` is this ZigBase binary's build version; framework applications should
pass their own API or release version when that distinction matters to generated clients.
Changing `--api-version` never changes `x-zigbase-contract-version`.

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

A consumer route gated by `authed_collection` always exports `x-zigbase-auth-collection` from its
comptime route metadata. It does not require that collection to exist in the inspected live
database, and it does not emit resource `x-zigbase-collection` markers. Those resource markers are
reserved for generated collection CRUD operations.

## Collection contract

Every non-system collection contributes these literal paths:

- `GET` and `POST /api/collections/<name>/records`;
- `GET`, `PATCH`, and `DELETE /api/collections/<name>/records/{id}`.

Resource markers are inseparable from that method/path matrix. Their
`x-zigbase-collection` value equals `<name>`, and `x-zigbase-collection-type` is consistent for
every operation on the collection. Consumer routes never borrow either resource marker.
They also cannot overlap an enabled built-in route of the same method or an engine-owned prefix;
the framework rejects such declarations at compile time.

Record, create, update, and list components preserve field types and applicable length, pattern,
numeric, enum, selection-count, relation, file-size, and MIME constraints. Record schemas include
`id`, `created`, and `updated`, while leaving properties optional because `?fields=` can project
them away. Unset non-required fields are nullable. Integer and fixed-decimal record values use
their actual decimal-string wire form; create/update inputs accept either strings or JSON numbers.
Auth create/update schemas include the write-only password fields accepted by those endpoints.
Engine-only credential columns such as `passwordHash` and `tokenKey` are never exported. A
user-defined hidden field remains visible to contract tooling as `writeOnly: true`.

Every generated collection operation also carries `x-zigbase-collection` with the authoritative
collection name and `x-zigbase-collection-type` with its schema kind (`base`, `auth`, or `view`).
Consumers must use the name marker to bind an operation to its collection and the type marker to
distinguish authentication collections rather than re-deriving either value from URL segments,
`password`, `passwordConfirm`, or other field names; ordinary hidden fields are also write-only and
are not an auth signal.

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
the ordinary [API reference](https://github.com/valthon/zigbase/blob/main/docs/api.md); their omission from this document is explicit, not a claim
that the running server lacks them.

These six keys are an exact boolean contract: `collections` is true; `admin`, `realtime`,
`fileBytes`, and `allAuthMethods` are false; and `consumerRoutes` is true exactly when the exported
`paths` contain at least one consumer operation. Missing, extra, non-boolean, or internally
incoherent coverage metadata is invalid rather than a forward-compatible hint.

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
