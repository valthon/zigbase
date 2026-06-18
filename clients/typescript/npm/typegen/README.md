# @zigbase/typegen

Generate a fully typed TypeScript client from a ZigBase schema — no Zig toolchain required.
The generator reads your schema offline from a provisioned data directory, or live over HTTP,
and emits the typed `db` / realtime / files surface for use with `@zigbase/client`.

## Quick start

```sh
# Offline — reads an already-provisioned data directory (no server needed):
npx @zigbase/typegen --data-dir ./zb_data --out src/zbase.gen.ts

# Live — against a running instance (superuser credentials required):
npx @zigbase/typegen --url https://api.example.com \
  --admin-email admin@example.com \
  --admin-password 'your-password' \
  --out src/zbase.gen.ts
```

## Schema sources (exactly one required)

| Flag | Behavior |
| --- | --- |
| `--data-dir <path>` | **Offline.** Reads the server's data directory directly — no auth, no running server required. The directory must already have been provisioned by a prior `serve` run; a freshly-created or empty data directory has no collections to read. |
| `--url <origin> --admin-email <e> --admin-password <p>` | **Live.** Calls `GET /api/collections` on the running instance using superuser credentials. |

## Flags

| Flag | Default | Purpose |
| --- | --- | --- |
| `--out <file>` | *(required)* | Path to write the generated TypeScript file. |
| `--api-prefix <p>` | `/api` | API path prefix used in the generated client. |
| `--client-name <name>` | `ZbClient` | Name of the generated client factory. |
| `--check` | — | Staleness gate: exits non-zero if the out file is out of date without writing it. Useful in CI. |

## Output

The generated file exports the typed `db` / realtime / files surface — a schema-aware client
that calls into `@zigbase/client` + `@zigbase/client/typed`. It does **not** emit `rpc.*`:
custom routes are not visible at runtime and require the comptime generator (`zig build gen-client`)
if you have the Zig source.

## Dependencies

The generated file imports `@zigbase/client` and `@zigbase/client/typed`. Install them separately:

```sh
npm install @zigbase/client
```

No Zig toolchain is needed — `@zigbase/typegen` bundles the codegen engine through
`@zigbase/server`, which ships prebuilt platform binaries.

## How it works

`@zigbase/typegen` depends on `@zigbase/server`, which resolves the correct platform binary via
optional dependencies (`@zigbase/server-linux-x64`, `@zigbase/server-linux-arm64`,
`@zigbase/server-darwin-x64`, `@zigbase/server-darwin-arm64`). The wrapper invokes the server's
built-in `typegen` subcommand and writes the result to `--out`.

## Supported platforms

- `linux-x64`
- `linux-arm64`
- `darwin-x64`
- `darwin-arm64`

(Windows support is not yet available.)

## Requirements

- Node.js >=18
