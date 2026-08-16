# OpenAPI export — design

**Date:** 2026-08-15
**Status:** Approved by the AI-agents program for implementation
**Program:** [ZigBase AI-Agents Program](2026-08-08-ai-agents-program-design.md), contracts lane
**Baseline:** `codex/sp4-foundation` @ `5b6d9f3f`

## 1. Goal

Ship `zigbase openapi`: a deterministic OpenAPI description of a ZigBase application's
collection API and consumer-declared routes. The output gives agents and ordinary OpenAPI tooling
the same schema and typed-route information ZigBase already uses for provisioning and client
generation, without starting a server or adding a protocol sidecar.

The exporter is an inspection surface. It does not change the database, provision collections,
make application HTTP requests, or infer contracts from handler source. SQLite export is fully
offline; PostgreSQL export connects only to the configured database URL for metadata inspection.

## 2. Scope

### In scope

- OpenAPI 3.1.2 JSON with the OpenAPI 3.1 base dialect (JSON Schema 2020-12 semantics).
- Live, non-system collections read from `--data-dir`, including field constraints and literal
  collection CRUD paths.
- Comptime consumer-route metadata from `App.routes`, including typed request/response schemas.
- Honest security metadata for public, authenticated, superuser, collection-scoped authenticated,
  and path-secret routes.
- Stable operation ids, deterministic ordering, `--out`, `--title`, `--api-version`, and
  `--server`.
- Tests for parser behavior, schema mapping, paths, security, secret redaction, deterministic
  output, framework route plumbing, CLI files/stdout, help, docs, and generated AGENTS guidance.

### Out of scope

- OpenAPI 3.2-only features.
- YAML output.
- Serving the document from an HTTP endpoint.
- Admin/superuser management, realtime transports, file byte endpoints, and every auth-method
  variant. This first contract covers collection CRUD plus consumer routes; omitted built-ins are
  named in a root `x-zigbase-coverage` object so the document cannot imply full server coverage.
- Guessing response bodies for untyped handlers. They are included with method/path/security and
  an explicit `x-zigbase-untyped: true`, but only a generic response contract.
- Handler annotations or prose descriptions. Those can be added later without changing this
  document's core shape.

## 3. Command contract

```text
zigbase openapi [--data-dir PATH] [--out FILE]
                [--title TEXT] [--api-version VERSION] [--server URL]
```

- JSON is the only format and is written to stdout by default.
- `--out` creates parent directories and atomically replaces the requested artifact in the same
  manner as other generated CLI artifacts.
- `--data-dir` selects the live logical collection model. System collections are excluded.
- `--title` defaults to `ZigBase API`.
- `--api-version` defaults to the ZigBase build version; it is application metadata and is
  deliberately separate from the root `openapi: "3.1.2"` field.
- `--server` adds one Server Object. With no flag, `servers` is omitted rather than inventing a
  deployment origin.
- Unknown flags, repeated value flags, and missing values fail through the existing CLI parse
  contract. `zigbase openapi --help` has a dedicated help topic.

The shipped box binary exports only live collections because it has no consumer routes. A
framework application's `App.runCli` passes its comptime `App.routes`, so the same command includes
both live collections and that application's custom route surface.

## 4. Document shape

The root is deterministic JSON:

```json
{
  "openapi": "3.1.2",
  "jsonSchemaDialect": "https://spec.openapis.org/oas/3.1/dialect/base",
  "info": {"title": "ZigBase API", "version": "0.13.0"},
  "paths": {},
  "components": {
    "securitySchemes": {
      "bearerAuth": {"type": "http", "scheme": "bearer", "bearerFormat": "JWT"}
    },
    "schemas": {}
  },
  "x-zigbase-coverage": {
    "collections": true,
    "consumerRoutes": true,
    "admin": false,
    "realtime": false,
    "fileBytes": false,
    "allAuthMethods": false
  }
}
```

Collections and component names are sorted by collection name; paths are inserted in stable order.
The output ends in one newline.

## 5. Collection mapping

Each collection produces named record and write schemas plus literal paths:

- `GET /api/collections/<name>/records` — list result;
- `POST /api/collections/<name>/records` — create;
- `GET /api/collections/<name>/records/{id}` — view;
- `PATCH /api/collections/<name>/records/{id}` — update; and
- `DELETE /api/collections/<name>/records/{id}` — delete.

All paths exist in the document even when locked. Access rules are part of the contract, not a
reason to hide a route:

- `@public`: `security: []`, `x-zigbase-access: "public"`;
- `null`: bearer security, `x-zigbase-access: "locked"`;
- any other expression: no normative OpenAPI security requirement,
  `x-zigbase-access: "conditional"`, and `x-zigbase-rule` containing the exact expression.

This avoids the dangerous false claim that an arbitrary rule always requires a token. The rule is
configuration, not a credential, and is already exposed by schema APIs.

Field schemas map from `schema.FieldOptions`:

- text/editor → string; email → string/email; URL → string/uri;
- date/autodate → string/date-time;
- bool → boolean;
- int number → integer; float/fixed → number, with fixed scale represented as `multipleOf`;
- JSON → unconstrained JSON Schema;
- select → string enum, array when multi-value;
- relation → record-id string, array when multi-value;
- file → filename string, array when multi-value.

Applicable min/max, length, pattern, enum, item-count, and required constraints are preserved.
Record schemas include `id`, `created`, and `updated`. Write schemas omit read-only fields;
auth-create adds `password` and `passwordConfirm` without ever emitting a real value. Hidden fields
remain documented but carry `writeOnly: true` so tooling does not promise them in responses.

## 6. Consumer routes

`events.RouteMeta` is extended with redacted security metadata. A path-secret route records only
the parameter name/location and mismatch behavior; it never carries or serializes the configured
secret or secret-store key. Collection-scoped auth records the collection name and superuser
allowance.

Zig `:param` path segments become OpenAPI `{param}` templates and receive required string Path
Parameters. A path-secret parameter reuses that parameter when it is in the path, or adds a query
or header parameter in its declared location with `writeOnly: true`.

Typed routes map their bounded Zig input/output subset to inline JSON Schemas:

- `void` → no request body or response content;
- bool/int/float/string/enum/optional/slice/plain struct → the corresponding JSON Schema;
- `std.json.Value` → an unconstrained schema.

GET/DELETE inputs are query parameters for top-level struct fields. Other typed inputs use an
`application/json` request body. Success is `200` for JSON output and `204` for any void typed
output, matching the route thunk's wire behavior.
Every operation references the canonical ZigBase error envelope for `4XX` and `5XX` defaults.

Untyped routes are retained with `x-zigbase-untyped: true` and a generic successful response. The
exporter does not fabricate a JSON body for handlers that deliberately own raw responses.

## 7. Security and failure rules

- No configured secret value, secret-store key, token, password, or database row is serialized.
- Public access is represented explicitly, not upgraded to bearer auth in documentation.
- Superuser and authenticated routes share JWT bearer mechanics but carry distinct
  `x-zigbase-auth` metadata.
- Invalid route metadata remains a compile-time error at `App` construction.
- Export allocation or database errors fail non-zero and never leave partial stdout JSON.
- An output file is assembled fully before replacement so a failed export cannot truncate a
  previously valid artifact.

## 8. Verification and compatibility

Tests parse output back through `std.json`, assert the exact OpenAPI version/dialect and stable
operation ids, verify collection and route schemas, and scan serialized output for fixture secret
values. A representative framework fixture proves custom routes reach `App.runCli`; the shipped
binary proves the collection-only mode.

This is additive before 1.0: no existing REST or CLI wire shape changes. The OpenAPI document is a
new versioned contract; future breaking document-shape changes require a changelog entry and a
documented compatibility decision.
