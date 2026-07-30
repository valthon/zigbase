# zigbase

**This package is an alias. The canonical package is
[`@zigbase/server`](https://www.npmjs.com/package/@zigbase/server).**

It exists so the unscoped npm name `zigbase` belongs to the project and so `npx zigbase` works.
It contains no binary and no logic of its own: it depends on `@zigbase/server` at the exact same
version and forwards to it.

```sh
npx zigbase serve --http-port 8090 --data-dir ./zb_data
```

Prefer `@zigbase/server` in a project's `dependencies` — it is the package that documents the
platform matrix, ships the launcher, and exposes `binaryPath()`. This one is a convenience name.

## What you get

- The `zigbase` command, forwarded verbatim to `@zigbase/server`'s launcher (same argv, same exit
  code).
- `require("zigbase")` re-exports `@zigbase/server`, so `binaryPath()` works through either name.

Every version of `zigbase` pins one exact `@zigbase/server` version, so `zigbase@X.Y.Z` and
`@zigbase/server@X.Y.Z` are always the same server build. Resolver errors are reported as
`@zigbase/server: …` because that is where the resolution happens.

## Installing both packages

`@zigbase/server` also provides a `zigbase` command, so a project that depends on **both** has two
packages claiming the same bin name. That is fine: the install succeeds with no warning, and npm
links `@zigbase/server`'s copy into `node_modules/.bin/zigbase` (measured with npm 11 on both
declaration orders). Both copies exec the same platform binary and forward argv and the exit code
identically, so which one wins is not observable. Nothing to work around — but depending on
`@zigbase/server` alone is the tidier choice.

## Supported platforms

`linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64` (Windows is not yet supported). The
platform binary is selected by `@zigbase/server`'s optional dependencies; see its README for
details.

## Requirements

- Node.js >=18

Apache-2.0. Source: <https://github.com/valthon/zigbase>
