# Releasing `@zigbase/client`

The TypeScript SDK is versioned **independently** of the ZigBase server.

- The **server** is released with `vX` tags (e.g. `v0.4.0`).
- The **SDK** is released with `client-v*` tags (e.g. `client-v0.1.0`).

A `client-v*` tag triggers the [`release-sdk.yml`](../../.github/workflows/release-sdk.yml)
workflow, which typechecks, tests, builds, asserts the tag matches
`package.json`, and publishes to npm with provenance. Nothing else publishes the
SDK — a normal push or PR never does.

## Prerequisites (one-time)

The release workflow is **dormant** until both are true:

1. The npm org `@zigbase` exists and you can publish `@zigbase/client` to it.
2. Authentication is wired, EITHER:
   - a `NPM_TOKEN` repository secret (classic token auth — an automation token
     with publish rights), **or**
   - npm **trusted publishing (OIDC)** configured for the `release-sdk.yml`
     workflow. With OIDC you can delete the `NODE_AUTH_TOKEN` line in the
     workflow; `id-token: write` + `--provenance` are enough.

Until both are done, do **not** push a `client-v*` tag — the publish step would
fail (no account / no auth).

## Cutting a release

1. Bump the version in `clients/typescript/package.json` (e.g. `0.1.0` → `0.1.1`).
   Follow semver.
2. Commit the bump:
   ```bash
   git commit -am "chore(ts-sdk): release client-v0.1.1"
   ```
3. Tag with the matching `client-v<version>` tag (the version after the prefix
   MUST equal `package.json`'s `version`, or the workflow fails its assertion):
   ```bash
   git tag client-v0.1.1
   ```
4. Push the commit and the tag:
   ```bash
   git push origin main
   git push origin client-v0.1.1
   ```
5. The `release-sdk.yml` workflow runs on the pushed tag and publishes
   `@zigbase/client@0.1.1` to npm with `--provenance`.

## Notes

- `dist/` is gitignored; the package's `prepack` script (`npm run build`) rebuilds
  it before `npm pack`/`npm publish`, so a clean checkout always ships a built
  tarball.
- The published tarball contains `dist/**`, `README.md`, `LICENSE`, and
  `package.json` (npm always includes the latter three). Source, tests, and
  config are excluded via the `files` field.
- The workflow does **not** build or run the Zig server / integration tests —
  the merge CI already covers those. SDK releases stay fast and deterministic.
