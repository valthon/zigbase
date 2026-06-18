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

Push a tag to trigger the `release-server.yml` workflow:

- **Server packages:** push a `server-vX.Y.Z` tag (e.g. `server-v0.4.1`).
  The workflow cross-builds all four platform binaries and publishes all five
  `@zigbase/server*` packages with `--provenance`.
- **Typegen:** push a `typegen-vX.Y.Z` tag (e.g. `typegen-v0.2.0`).
  The workflow publishes `@zigbase/typegen` with `--provenance`.

The workflow uses `node clients/typescript/npm/publish.mjs --skip-build
--provenance [--what server|typegen]` — the same script as the manual path.

The workflow publishes **exclusively via OIDC trusted publishing** (`--provenance`,
`id-token: write` permission, no token). OIDC requires each package to already exist on the
registry, which is why the first publish is done manually (see below). After the first publish,
configure a per-package trusted publisher on npmjs.com for the `release-server.yml` workflow,
and all subsequent tag pushes will publish without any npm token.

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
   - Cross-build `zigbase-dist` for all four targets via
     `mise exec zig@0.16.0 -- zig build dist-server -Dtarget=<t> -Doptimize=ReleaseFast -Dcpu=baseline`.
   - Copy each binary into the corresponding `server-<key>/zigbase`.
   - Verify all `@zigbase/server*` packages share one version.
   - Publish the four platform packages, then the meta, then `@zigbase/typegen`.
   - Skip any package whose exact version is already on the registry (safe to
     re-run after a partial failure).

## Bumping versions

### Server packages (`@zigbase/server*`)

All five packages share a version that must match `build.zig.zon`. To cut a
new server release:

1. Update `version` in `build.zig.zon`.
2. Update `version` in each of the five `package.json` files under
   `clients/typescript/npm/server*/` to match. The `optionalDependencies` in
   `server/package.json` must also be updated to exact-match the new version.
3. Commit:
   ```bash
   git commit -am "chore(npm): bump @zigbase/server* to 0.5.0"
   ```
4. Tag and push:
   ```bash
   git tag server-v0.5.0
   git push origin main
   git push origin server-v0.5.0
   ```

### Typegen (`@zigbase/typegen`)

1. Update `version` in `clients/typescript/npm/typegen/package.json`.
2. If the minimum compatible `@zigbase/server` version changed, update the
   `dependencies` range too.
3. Commit, tag `typegen-vX.Y.Z`, and push:
   ```bash
   git commit -am "chore(npm): bump @zigbase/typegen to 0.2.0"
   git tag typegen-v0.2.0
   git push origin main
   git push origin typegen-v0.2.0
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
