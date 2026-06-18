# @zigbase/server

The official prebuilt ZigBase server binary, typegen-enabled. Ships as a meta-launcher that
resolves the correct platform-specific binary from the corresponding `@zigbase/server-<platform>`
optional dependency — the same distribution strategy as `esbuild`.

## Usage

```sh
npx @zigbase/server serve --http-port 8090 --data-dir ./zb_data
```

The `zigbase` binary is also available on PATH after `npm install`:

```sh
zigbase serve --http-port 8090 --data-dir ./zb_data
zigbase --help
```

From Node.js, resolve the binary path programmatically:

```js
const { binaryPath } = require("@zigbase/server");
const bin = binaryPath(); // absolute path to the platform binary
```

## Supported platforms

| Platform | Package |
| --- | --- |
| Linux x64 | `@zigbase/server-linux-x64` |
| Linux arm64 | `@zigbase/server-linux-arm64` |
| macOS x64 | `@zigbase/server-darwin-x64` |
| macOS arm64 | `@zigbase/server-darwin-arm64` |

Windows support is not yet available.

The per-platform packages are installed automatically as optional dependencies — you do not need
to depend on them directly. If no platform package matches the current host, `binaryPath()` throws
a clear error.

## Distribution model

`@zigbase/server` is the meta-launcher. It contains no binary itself; it declares each
`@zigbase/server-<platform>` package as an `optionalDependency` so npm/yarn/pnpm installs only
the one that matches the host. This keeps install size minimal and mirrors the approach used by
`esbuild`.

## Typegen

`@zigbase/server` ships a typegen-enabled binary. `@zigbase/typegen` builds on it to provide
`npx @zigbase/typegen` — no Zig toolchain required. See [`@zigbase/typegen`](https://www.npmjs.com/package/@zigbase/typegen).

## Requirements

- Node.js >=18
- One of the supported platforms listed above
