# Releasing `@zigbase/server*` and `@zigbase/typegen`

The npm packages under this directory are versioned **independently** of the
TypeScript SDK (`@zigbase/client`).

- **`@zigbase/server*`** (five packages: four platform + one meta) track the
  ZigBase server binary. Their version matches `build.zig.zon`. They are
  released together — all five always share the same version.
- **`@zigbase/typegen`** is released independently and follows its own semver.

## Package dependency order

Platform packages must exist on the registry before the meta package can be
installed, and the meta package must exist before `@zigbase/typegen` can be
installed (the typegen wrapper depends on `@zigbase/server`). The publish script
enforces this order automatically:

```
@zigbase/server-linux-x64
@zigbase/server-linux-arm64
@zigbase/server-darwin-x64
@zigbase/server-darwin-arm64
@zigbase/server          ← meta (optionalDependencies → the four above)
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
`@zigbase/server*` on npm with `--provenance`.

The five server `package.json` files are **generated** from `targets.json` +
`build.zig.zon` via `gen-server-packages.mjs` — do not edit them directly.

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
   Confirm it prints all six packages in dependency order and exits 0.

3. Publish for real:
   ```bash
   node clients/typescript/npm/publish.mjs
   ```
   The script will:
   - Cross-build `zigbase` for all four targets via
     `mise exec zig@0.16.0 -- zig build -Dtarget=<t> -Doptimize=ReleaseSafe -Dcpu=baseline`.
   - Copy each binary into the corresponding `server-<key>/zigbase`.
   - Verify all `@zigbase/server*` packages share one version.
   - Publish the four platform packages, then the meta, then `@zigbase/typegen`.
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
  --what <scope>  Publish only server packages (server) or only typegen
                  (typegen). Default: all.
```

The script is idempotent: it checks `npm view <name>@<version> version` before
publishing and skips packages already on the registry.

## Notes

- Platform binaries (`server-*/zigbase`) are gitignored. They are produced by
  the build step or must be dropped in manually when using `--skip-build`.
- The `@zigbase/server` meta package has no binary of its own — it only pulls
  the right platform package via `optionalDependencies`.
- `@zigbase/typegen` ships pure JS; no binary or build step required.
