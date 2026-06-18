# ZigBase TS SDK — SP3b: Typegen Distribution & Live Proof

**Status:** Approved design (2026-06-18)
**Tier:** SP3b — the distribution & validation half of SP3 (the runtime-introspection tier). Follows SP3a (the `zigbase typegen` engine, merged PR #31).
**Predecessor:** `2026-06-18-zigbase-ts-sdk-sp3-runtime-introspection-design.md` (§10 sketched this).

---

## 1. Goal

Make the SP3a runtime typegen engine usable by a JavaScript developer with **no Zig toolchain**, and prove the engine works end-to-end against a live server.

Two deliverables:
1. **npm distribution** — `npx @zigbase/typegen --data-dir … --out …` runs prebuilt per-platform ZigBase server binaries (built with comptime `enable_typegen = true`), distributed esbuild-style.
2. **Live e2e** — a TypeScript integration test that runs `typegen` against a live `dating-server` (both `--url` and `--data-dir` modes), then imports the generated client and exercises it, proving introspection → generate → use.

## 2. Package Architecture (layered, esbuild-style at the server level)

The platform split lives at the **server** level, not typegen. Typegen is a thin, platform-agnostic wrapper.

```
@zigbase/server-linux-x64      ┐
@zigbase/server-linux-arm64    │  each ships ONE prebuilt binary + os/cpu gating.
@zigbase/server-darwin-x64     │  Binaries are injected by CI / the bootstrap
@zigbase/server-darwin-arm64   ┘  script — NOT committed to git.
        ▲ optionalDependencies (npm installs only the matching one)
@zigbase/server   ── meta package. A small JS launcher resolves the matching
                     platform package's binary and `execFileSync`s it with argv
                     forwarded. Exposes `bin` (so `npx @zigbase/server serve …`
                     works) AND a programmatic `binaryPath()` export.
        ▲ dependency
@zigbase/typegen  ── platform-agnostic wrapper. A `bin` script resolves
                     `@zigbase/server`'s `binaryPath()` and runs
                     `<bin> typegen <forwarded argv>`. No dependency on the SDK.
```

- `npx @zigbase/typegen --data-dir ./zb_data --out src/zbase.gen.ts` → `<server-bin> typegen --data-dir ./zb_data --out src/zbase.gen.ts`.
- The **generated artifact** (`zbase.gen.ts`) imports `@zigbase/client` + `@zigbase/client/typed`; the user installs the base SDK separately. `@zigbase/typegen` itself does **not** depend on the SDK (the generator never imports it).
- The base SDK stays published as `@zigbase/client` (renaming it is out of scope here).

### 2.1 The `@zigbase/server` launcher
`bin/zigbase.js` (the package `bin`):
- Computes the platform key (`${process.platform}-${process.arch}` → `linux-x64`, `darwin-arm64`, …).
- Resolves the binary via `require.resolve('@zigbase/server-<key>/<binary-name>')` (the platform package declares the binary in its `files`/exports).
- `execFileSync(bin, process.argv.slice(2), { stdio: 'inherit' })`; propagates the child exit code.
- On no matching optionalDependency installed → a clear error naming the unsupported platform and the supported set.
- A programmatic entry (`index.js` exporting `binaryPath(): string`) so `@zigbase/typegen` resolves the binary without re-implementing platform logic.

### 2.2 The `@zigbase/typegen` wrapper
`bin/typegen.js`: `#!/usr/bin/env node`; `const bin = require('@zigbase/server').binaryPath();` then `execFileSync(bin, ['typegen', ...process.argv.slice(2)], { stdio: 'inherit' })`, propagating the exit code. ~15 lines, no platform logic.

### 2.3 Monorepo layout
The distribution packages nest under `clients/typescript/npm/` (the existing `@zigbase/client` package stays at the `clients/typescript/` root, unchanged). Nesting under `clients/typescript/` leaves room for future `clients/<lang>/` siblings. The committed templates (package.json, launchers, READMEs) live here; CI / the bootstrap script inject binaries into copies before publish:
```
clients/typescript/                      @zigbase/client — the base SDK (unchanged)
clients/typescript/npm/server/           package.json (meta, optionalDependencies), bin/zigbase.js, index.js, README.md
clients/typescript/npm/server-linux-x64/    package.json (os/cpu, files:["zigbase"]), README.md   (binary injected)
clients/typescript/npm/server-linux-arm64/  "
clients/typescript/npm/server-darwin-x64/   "
clients/typescript/npm/server-darwin-arm64/ "
clients/typescript/npm/typegen/          package.json (depends @zigbase/server), bin/typegen.js, README.md
clients/typescript/npm/publish.mjs       bootstrap/fallback manual publish script
clients/typescript/npm/RELEASING.md      release runbook (OIDC + manual bootstrap)
```

## 3. The Distributed Binary

The dev `zigbase` binary keeps `enable_typegen = false` (production server carries no codegen — the SP3a default). The **official distributed build flips it on**:

- New thin root `src/main_dist.zig`: `pub fn main(init) !void { return zigbase.App(.{ .enable_typegen = true }).runCli(init); }`.
- New `build.zig` executable target (e.g. step `dist-server`) building it, honoring `b.standardTargetOptions` + `b.standardOptimizeOption`, so the release matrix passes `-Dtarget=<t> -Doptimize=ReleaseFast -Dcpu=baseline`.
- The packaged binary is named `zigbase` inside each platform package.

This is the SP3a-stated "our official static builds set `enable_typegen` true," realized as a distinct release target so the default dev/CI `zigbase` is unchanged.

## 4. Platform Matrix & CI Build

Four targets (Windows deferred — facil.io is POSIX-centric):

| npm key | Zig target | Runner | Notes |
|---|---|---|---|
| `linux-x64` | `x86_64-linux-musl` | `ubuntu-latest` | musl-static — runs on glibc AND Alpine |
| `linux-arm64` | `aarch64-linux-musl` | `ubuntu-latest` (cross) | musl-static |
| `darwin-arm64` | `aarch64-macos` | `macos-latest` (arm64) | native on the Apple-Silicon runner |
| `darwin-x64` | `x86_64-macos` | `macos-latest` (arm64) | cross-built on the same macOS runner (SDK present for both arches) |

Each builds via `mise exec zig@0.16.0 -- zig build dist-server -Dtarget=… -Doptimize=ReleaseFast -Dcpu=baseline`. Linux targets cross-compile on ubuntu; both darwin arches build on the macOS runner (it carries the SDK for both, sidestepping the linux→macOS cross-link risk). The matrix runs only in the release workflow (not on every PR — keeps PR CI fast); a smoke build of the `dist-server` host target IS added to the regular `build` job so the distribution root never silently breaks.

## 5. Release Pipeline (OIDC trusted publishing + manual bootstrap)

### 5.1 CI workflow (`.github/workflows/release-server.yml`)
- Trigger: `push` tags `server-v*` (server matrix + meta) and `typegen-v*` (the wrapper).
- `permissions: { contents: read, id-token: write }`.
- **OIDC trusted publishing**: `npm publish --provenance --access public` with **no `NODE_AUTH_TOKEN`** — npm validates the run against the trusted-publisher config registered on npmjs.com per package. (Modern npm OIDC trusted publishing; mirrors the structure of the existing `release-sdk.yml` minus the long-lived token.)
- Build the 4-target matrix → inject each binary into its `@zigbase/server-<platform>` package copy → publish the four platform packages, then the `@zigbase/server` meta, then (on a `typegen-v*` tag) `@zigbase/typegen`. Dependency order matters (a meta/wrapper referencing an unpublished version would fail).
- Tag-suffix ↔ package-version assertion, mirroring `release-sdk.yml`'s check.

### 5.2 Manual bootstrap/fallback (`clients/typescript/npm/publish.mjs`)
Trusted publishing cannot be configured until a package already exists, so the **first** publish of each package is manual. A Node script the user runs locally after `npm login`:
- `--dry-run` (default off): run `npm publish --dry-run` for every package, publish nothing.
- `--skip-build`: use binaries already present (e.g. downloaded CI artifacts) instead of building.
- Without `--skip-build`: builds all four targets via `zig build dist-server -Dtarget=…` (works from macOS for all four; from Linux the darwin targets need the SDK — documented).
- Verifies version consistency (all `@zigbase/server*` share one version from `build.zig.zon`; `@zigbase/typegen` its own), injects binaries into package copies, and `npm publish`es in dependency order with the user's credentials.
- Idempotent-ish: skips a package whose exact version is already on the registry (warns), so a partial run can be resumed.

### 5.3 Versioning
- `@zigbase/server` + the four platform packages share the **server** version, sourced from `build.zig.zon` (currently `0.4.0`). Platform packages are pinned to the exact meta version; the meta's `optionalDependencies` pin them exactly.
- `@zigbase/typegen` versions independently and depends on a compatible `@zigbase/server` range (e.g. `^0.4.0`).
- Tags: `server-vX.Y.Z`, `typegen-vX.Y.Z` (distinct from the SDK's `client-v*`).
- **Prerequisite (operator):** the `@zigbase` npm org + per-package trusted-publisher config. Nothing publishes from CI until a tag is pushed AND OIDC is configured; the bootstrap script covers the pre-OIDC first publish.

## 6. Live e2e (full round-trip)

New integration test (vitest, under `clients/typescript/test/integration/`, using the existing harness pattern). `dating-server` already has `enable_typegen = true`.

1. `startAppServer({ bin: DATING_BIN })` → `{ url, superuser, dataDir, stop }`. **Harness change:** `startAppServer` returns its `dataDir` (currently internal) so the test can point `typegen --data-dir` at it.
2. Run `dating-server typegen --url <url> --admin-email <e> --admin-password <p> --out <gen>` AND `dating-server typegen --data-dir <dataDir> --out <gen2>`, with `ZBASE_INREPO=1`, generating into a **gitignored sibling of the committed golden** (`test/codegen/dating/<tmp>.gen.ts`, same directory depth so the generated file's `../../../src` imports resolve).
3. Assert both generated outputs are **byte-identical to the committed `zbase.runtime.gen.ts`** (live `--url` and offline `--data-dir` agree with the golden).
4. **Dynamically import** the generated file and exercise it against the live server: auth (superuser or a seeded user), `db.*` CRUD, a nested-filter list, an `expand`, an int/fixed-coercion write/read, and a realtime subscription round-trip. Mirrors the existing comptime dating e2e but drives the *runtime-generated* client.
5. Clean up the generated temp file.

Plus a **wrapper smoke test**: with a locally-built `dist-server` binary placed where a `@zigbase/server-<platform>` package would have it, assert the `@zigbase/typegen` launcher (`bin/typegen.js`) resolves the binary and forwards args (e.g. `--help` exits 0 and prints typegen usage). This validates the JS launcher logic without a published package.

The npm packaging itself is validated by `npm publish --dry-run` / `npm pack` in CI (the `dist-server` smoke build + a packaging-lint job), not by a network publish on PRs.

## 7. Error Handling

- Launcher: unsupported platform → clear message listing supported targets; missing optionalDependency (e.g. `--no-optional` install) → actionable error.
- Wrapper: non-zero `typegen` exit propagated verbatim; the underlying engine's friendly errors (unprovisioned data dir, auth failure, unreachable URL) pass through `stdio: 'inherit'`.
- Release workflow: tag/version mismatch fails fast; a platform build failure fails the matrix before any publish.
- Bootstrap script: refuses to publish on version mismatch; skips already-published versions; `--dry-run` for safe rehearsal.

## 8. Docs

- `clients/typescript/npm/typegen/README.md` (published) — install, `npx @zigbase/typegen` usage, both source modes, the no-rpc note, that the generated client needs `@zigbase/client`.
- `clients/typescript/npm/server/README.md` (published) — `npx @zigbase/server serve …`, the platform matrix, that it's the typegen-enabled official build.
- `clients/typescript/npm/RELEASING.md` — the OIDC + manual-bootstrap runbook, tag conventions, the first-publish ordering.
- `docs/typescript-sdk.md` ↔ `site/` mirror — add: the runtime generator is installable via `npx @zigbase/typegen` (no Zig toolchain), alongside the existing data-dir/url docs.

## 9. Scope Boundaries

- **Windows deferred** (facil.io). Launcher errors clearly on win32.
- **No SDK rename.** Base SDK stays `@zigbase/client`.
- **No automatic version bumping** — releases are tag-driven and version-asserted, as the existing SDK release is.
- The live e2e validates the **engine** via `dating-server`; the **npm launcher** is validated by the smoke test + dry-run packaging. A published-package end-to-end install test is out of scope for v1 (it requires a real registry publish).

## 10. Decomposition (for the plan)

Cohesive single spec; the plan will break into ~tasks: (a) `src/main_dist.zig` + `dist-server` build target + host smoke build in CI; (b) `clients/typescript/npm/` package scaffolding (server meta launcher + `binaryPath()`, the four platform package templates, the typegen wrapper) + wrapper smoke test; (c) the release workflow (OIDC, matrix, dependency-ordered publish, version assertion); (d) `clients/typescript/npm/publish.mjs` bootstrap script; (e) the live round-trip e2e + `startAppServer` `dataDir` change; (f) docs.
