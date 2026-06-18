# @zigbase/server

ZigBase server — official prebuilt binary distribution (typegen-enabled).

This package resolves the correct platform-specific binary from the corresponding
`@zigbase/server-<platform>` optional dependency and exposes it via `binaryPath()`.

## Usage

```js
const { binaryPath } = require("@zigbase/server");
const bin = binaryPath(); // absolute path to the zigbase binary
```

The `zigbase` bin is also available on PATH after `npm install`:

```sh
npx zigbase --help
```

## Supported platforms

- `linux-x64`
- `linux-arm64`
- `darwin-x64`
- `darwin-arm64`
