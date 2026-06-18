# @zigbase/typegen

Generate a typed TypeScript client from a running ZigBase instance's schema — no Zig toolchain required.

## Usage

```sh
npx @zigbase/typegen --data-dir /path/to/data --out ./src/generated
```

This runs the `typegen` subcommand of the bundled ZigBase server binary (fetched via `@zigbase/server`).

## How it works

`@zigbase/typegen` depends on `@zigbase/server`, which resolves the correct platform binary via optional
dependencies (`@zigbase/server-linux-x64`, etc.). The typegen wrapper simply invokes:

```
zigbase typegen <args>
```

## Requirements

- Node.js >=18
- A supported platform: `linux-x64`, `linux-arm64`, `darwin-x64`, or `darwin-arm64`
