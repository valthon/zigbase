# Releasing `@zigbase/server*`, `zigbase` and `@zigbase/typegen`

The npm packages under this directory are versioned **independently** of the
TypeScript SDK (`@zigbase/client`).

- **`@zigbase/server*`** (five packages: four platform + one meta) track the
  ZigBase server binary. Their version matches `build.zig.zon`. They are
  released together — all five always share the same version.
- **`zigbase`** (unscoped) is a thin alias of `@zigbase/server` that claims the
  bare name and makes `npx zigbase` work. It pins **one exact**
  `@zigbase/server` version, so it ships with every server release and carries
  the same version as it. It has no binary of its own.
- **`@zigbase/typegen`** is released independently and follows its own semver.

## Package dependency order

Platform packages must exist on the registry before the meta package can be
installed, the meta must exist before the `zigbase` alias resolves (it pins it
exactly), and before `@zigbase/typegen` can be installed (the typegen wrapper
depends on `@zigbase/server`). The publish script enforces this order
automatically:

```
@zigbase/server-linux-x64
@zigbase/server-linux-arm64
@zigbase/server-darwin-x64
@zigbase/server-darwin-arm64
@zigbase/server          ← meta (optionalDependencies → the four above)
zigbase                  ← alias (dependencies → @zigbase/server, exact version)
@zigbase/typegen         ← depends on @zigbase/server
```

## Prerequisites (one-time)

1. The npm org `@zigbase` must exist and you must have publish rights.
2. For the **first publish**, npm OIDC trusted publishing cannot be used because
   it requires the package to already exist on the registry. Bootstrap manually
   (see below). Afterwards, configure a trusted publisher for each package on
   [npmjs.com](https://npmjs.com).

## Normal releases — OIDC (after the bootstrap publish)

### Server / project release (`v*`)

Bump the `.version` field in `build.zig.zon` (one line), commit, tag, and push:

```bash
# 1. Edit build.zig.zon — update .version = "X.Y.Z"
git commit -am "chore: bump version to X.Y.Z"
git tag vX.Y.Z
git push --follow-tags
```

CI (`release.yml`) builds the zigbase binary once across all four targets and
ships the result to **both** the GitHub release (tarballs + SHA256SUMS) **and**
`@zigbase/server*` plus the `zigbase` alias on npm with `--provenance`.

The five server `package.json` files and `alias/package.json` are **generated**
from `targets.json` + `build.zig.zon` via `gen-server-packages.mjs` — do not edit
them directly. The alias's version and its `@zigbase/server` pin come from the
same value in one pass, so the two cannot drift; `publish.mjs` re-checks the pin
before publishing anyway.

A CI version guard (`scripts/assert-version.sh`) asserts the tag matches
`build.zig.zon` before any build or publish step runs.

### Typegen release (`typegen-v*`)

1. Update `version` in `clients/typescript/npm/typegen/package.json`.
2. If the minimum compatible `@zigbase/server` version changed, update the
   `dependencies` range too.
3. Commit, tag `typegen-vX.Y.Z`, and push:
   ```bash
   git commit -am "chore(npm): bump @zigbase/typegen to X.Y.Z"
   git tag typegen-vX.Y.Z
   git push --follow-tags
   ```
   CI asserts the tag matches `typegen/package.json` then publishes
   `@zigbase/typegen` with `--provenance`.

### Client SDK release (`client-v*`)

Bump `clients/typescript/package.json`, commit, tag `client-vX.Y.Z`, and push.
The `release-sdk.yml` workflow handles publishing `@zigbase/client`.

## Claiming the bare `zigbase` name (one-time, manual)

`zigbase` has never been published, and npm OIDC trusted publishing cannot
bootstrap a package that does not exist yet — so the **first** publish of the
alias must be done by a human with `npm login`, exactly like the original
`@zigbase/server*` bootstrap. Until that is done, the release workflow's
"Publish the bare `zigbase` alias" step fails with a 403 (the server packages in
the step before it still publish normally).

The alias needs no cross-build and no binaries, so it is a standalone step:

```bash
npm login
# Sanity: the version the alias will claim, and the pin it will carry.
node clients/typescript/npm/gen-server-packages.mjs
cat clients/typescript/npm/alias/package.json

# Rehearse, then publish just the alias:
node clients/typescript/npm/publish.mjs --skip-build --dry-run --what alias
node clients/typescript/npm/publish.mjs --skip-build --what alias
```

`--access public` is passed by `publish.mjs` for every package. For an unscoped
name it is the default, but it is **not** redundant: npm refuses to generate
provenance for a package it cannot confirm is public, so CI's `--provenance` run
needs it.

Two follow-ups once the name is claimed:

1. Configure a trusted publisher for `zigbase` on [npmjs.com](https://npmjs.com),
   so the release workflow's alias step stops 403ing.
2. Add a `zigbase` case to `.github/workflows/smoke-published.yml`, e.g.
   `npx --yes zigbase@latest --version`. That workflow exists to catch a publish
   that installs but cannot run — a new install path deserves a row in it. It is
   left out until the name exists, since a daily job cannot smoke-test a package
   that 404s.

Note the alias's version must exist as
`@zigbase/server@<same version>` on the registry, or the published alias is
uninstallable; publishing it right after a server release (or at a version
already released, e.g. `0.12.0`) satisfies that.

## First bootstrap publish (manual)

Run this from a machine that can cross-build all four targets. macOS is the
easiest choice because `zig` cross-compiles both Linux musl and macOS targets
out of the box.

1. Log in to npm:
   ```bash
   npm login
   ```

2. Rehearse with `--dry-run` (packs but does not upload):
   ```bash
   node clients/typescript/npm/publish.mjs --dry-run
   ```
   Confirm it prints all seven packages in dependency order and exits 0.

3. Publish for real:
   ```bash
   node clients/typescript/npm/publish.mjs
   ```
   The script will:
   - Cross-build `zigbase` for all four targets via
     `mise exec zig@0.16.0 -- zig build -Dtarget=<t> -Doptimize=ReleaseSafe -Dcpu=baseline`.
   - Copy each binary into the corresponding `server-<key>/zigbase`.
   - Verify all `@zigbase/server*` packages share one version, and that the
     `zigbase` alias carries that version and pins it exactly.
   - Publish the four platform packages, then the meta, then the `zigbase`
     alias, then `@zigbase/typegen`.
   - Skip any package whose exact version is already on the registry (safe to
     re-run after a partial failure).

## Manual fallback (CI down / first dry-run)

To release without GitHub Actions:

```bash
# Build + package tarballs + create GitHub release:
scripts/release.sh --publish

# Then publish to npm:
node clients/typescript/npm/publish.mjs --provenance
```

## Script reference

```
node clients/typescript/npm/publish.mjs [options]

  --dry-run       Pack but do not upload (passes --dry-run to npm publish).
  --skip-build    Skip the zig cross-build step; binaries must already exist.
  --provenance    Pass --provenance to npm publish (used by CI with OIDC).
  --what <scope>  Publish only the server packages (server), only the bare
                  `zigbase` alias (alias), or only typegen (typegen).
                  Default: all — server, then alias, then typegen.
```

`--what alias` regenerates the manifests, verifies the alias's version and its
`@zigbase/server` pin agree, and publishes only `zigbase`. It never builds a
binary.

The script is idempotent: it checks `npm view <name>@<version> version` before
publishing and skips packages already on the registry.

## Notes

- Platform binaries (`server-*/zigbase`) are gitignored. They are produced by
  the build step or must be dropped in manually when using `--skip-build`.
- The `@zigbase/server` meta package has no binary of its own — it only pulls
  the right platform package via `optionalDependencies`.
- `@zigbase/typegen` ships pure JS; no binary or build step required.
- So does the `zigbase` alias: three files (`bin/zigbase.js`, `index.js`,
  `README.md`), no resolver of its own. Both it and `@zigbase/server` declare a
  `zigbase` bin; installing both is harmless (npm links `@zigbase/server`'s, and
  the two are behaviourally identical). `test-alias-install.mjs` pins that, plus
  the `npx` path that requires the alias to declare a bin at all.
