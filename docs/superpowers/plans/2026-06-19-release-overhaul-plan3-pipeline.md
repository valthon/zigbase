# Release Overhaul — Plan 3: Unified `v*` Build-Once Pipeline

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One `v*` tag builds the server binary once and ships it to BOTH the GitHub release (tarballs) and npm (`@zigbase/server*`), with a `tag == build.zig.zon` version guard, folding the old `server-v*` tag into `v*` and consolidating the manual `scripts/release.sh` onto shared packaging logic.

**Architecture:** A new `.github/workflows/release.yml` triggers on `v*` (project release) and `typegen-v*`. On `v*`: a matrix `build` job compiles `zigbase` once per target (native runners) and uploads the binaries; a `github-release` job tars them (via a shared `scripts/package-tarball.sh`) and runs `gh release create`; a `publish-npm` job generates manifests and publishes `@zigbase/server*` via OIDC — both consuming the SAME build artifacts. A shared `scripts/assert-version.sh` enforces `tag == build.zig.zon .version` in CI and the manual script. `release-server.yml` is deleted; `release-sdk.yml` (`client-v*`) is un-dormanted; `scripts/release.sh` is refactored to use the shared scripts.

**Tech Stack:** GitHub Actions YAML, Bash, Zig 0.16 build, Node (publish.mjs from Plan 2).

## Global Constraints

- ONE build per release feeds both channels (build once → GitHub + npm). No second build for npm. (spec §7)
- One variant everywhere: `ReleaseSafe`, `-Dcpu=baseline` (already true post-Plan-1). (spec §5)
- The version guard asserts `tag(minus the v/prefix) == build.zig.zon .version` — the single source of truth. (spec §3, §7)
- Tag scheme: `v<X.Y.Z>` → GitHub release + `@zigbase/server*`; `client-v<X.Y.Z>` → `@zigbase/client`; `typegen-v<X.Y.Z>` → `@zigbase/typegen`. The old `server-v*` trigger is REMOVED. (spec §7)
- npm publishing stays OIDC trusted publishing (`--provenance`, `id-token: write`, no token). (spec §7)
- Tarball naming unchanged: `zigbase-<version>-<zig-target>.tar.gz` containing `zigbase` + `LICENSE` + `README.md` + `KNOWN_LIMITATIONS.md`; plus `SHA256SUMS`. (matches current `scripts/release.sh`)
- DRY: the tarball-packaging and version-guard logic each live in ONE script used by both CI and the manual path.
- Workflow changes can't be run locally — validate YAML + (if available) actionlint + shell-snippet unit tests + careful review. The true end-to-end is the real release (Plan-4 follow-up).

---

## File Structure

- `scripts/assert-version.sh` — **create**: `assert-version.sh <expected>` exits non-zero unless `build.zig.zon .version == <expected>`.
- `scripts/package-tarball.sh` — **create**: `package-tarball.sh <version> <target> <binary> <out-dir>` produces `<out>/zigbase-<version>-<target>.tar.gz`.
- `scripts/release.sh` — **modify**: use the two new scripts; `--publish` asserts the version then creates the GitHub release.
- `.github/workflows/release.yml` — **create**: the unified `v*` + `typegen-v*` workflow.
- `.github/workflows/release-server.yml` — **delete** (folded into `release.yml`).
- `.github/workflows/release-sdk.yml` — **modify**: un-dormant the header comment (it's active now), add the shared version guard.
- `clients/typescript/npm/RELEASING.md` — **modify**: document the `v*` one-line-bump-plus-tag flow.

---

## Task 1: Shared packaging + version-guard scripts; refactor `release.sh`

**Files:**
- Create: `scripts/assert-version.sh`, `scripts/package-tarball.sh`
- Modify: `scripts/release.sh`
- Test: a local shell exercise (build one target, package it, assert tarball contents; run the guard with match + mismatch)

**Interfaces:**
- Produces: `scripts/assert-version.sh <expected>` (exit 0 on match, 1 + `::error::` on mismatch); `scripts/package-tarball.sh <version> <target> <binary> <out-dir>` (writes `<out>/zigbase-<version>-<target>.tar.gz`). Task 2's workflow calls both.

- [ ] **Step 1: Write the failing test (a shell exercise script)**

Create `scripts/test-release-scripts.sh` (a throwaway local test; it is committed so CI/review can re-run it):

```bash
#!/usr/bin/env bash
# Local unit test for assert-version.sh + package-tarball.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ver="$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

# assert-version: matching version exits 0; mismatch exits non-zero.
scripts/assert-version.sh "$ver"
if scripts/assert-version.sh "0.0.0-nope" 2>/dev/null; then echo "FAIL: mismatch should have failed"; exit 1; fi

# package-tarball: build one target, package it, assert the tarball contains the expected entries.
mise exec zig@0.16.0 -- zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe -Dcpu=baseline
tmp="$(mktemp -d)"
scripts/package-tarball.sh "$ver" "x86_64-linux-musl" zig-out/bin/zigbase "$tmp"
tarball="$tmp/zigbase-${ver}-x86_64-linux-musl.tar.gz"
test -f "$tarball" || { echo "FAIL: tarball not created"; exit 1; }
entries="$(tar -tzf "$tarball")"
for want in "zigbase-${ver}-x86_64-linux-musl/zigbase" "zigbase-${ver}-x86_64-linux-musl/LICENSE" "zigbase-${ver}-x86_64-linux-musl/README.md" "zigbase-${ver}-x86_64-linux-musl/KNOWN_LIMITATIONS.md"; do
  echo "$entries" | grep -qF "$want" || { echo "FAIL: tarball missing $want"; exit 1; }
done
rm -rf "$tmp"
echo "release-scripts test OK"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x scripts/test-release-scripts.sh && scripts/test-release-scripts.sh 2>&1 | tail -5`
Expected: FAIL — `scripts/assert-version.sh: No such file or directory` (the scripts don't exist yet).

- [ ] **Step 3: Create `scripts/assert-version.sh`**

```bash
#!/usr/bin/env bash
# Assert that <expected> matches build.zig.zon's .version (the single source of truth).
# Usage: scripts/assert-version.sh <expected-version>
set -euo pipefail
cd "$(dirname "$0")/.."
expected="${1:?usage: assert-version.sh <expected-version>}"
actual="$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
echo "expected=$expected build.zig.zon=$actual"
if [ "$expected" != "$actual" ]; then
  echo "::error::version mismatch: tag implies $expected but build.zig.zon has $actual" >&2
  exit 1
fi
```

- [ ] **Step 4: Create `scripts/package-tarball.sh`**

```bash
#!/usr/bin/env bash
# Package one target's zigbase binary into a release tarball:
#   <out>/zigbase-<version>-<target>.tar.gz  containing
#   zigbase-<version>-<target>/{zigbase,LICENSE,README.md,KNOWN_LIMITATIONS.md}
# Usage: scripts/package-tarball.sh <version> <target> <binary-path> <out-dir>
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?version}"; target="${2:?target}"; binary="${3:?binary}"; out="${4:?out-dir}"
name="zigbase-${version}-${target}"
staging="$out/$name"
mkdir -p "$staging"
cp "$binary" "$staging/zigbase"
chmod +x "$staging/zigbase"
cp LICENSE README.md KNOWN_LIMITATIONS.md "$staging/"
tar -czf "$out/${name}.tar.gz" -C "$out" "$name"
rm -rf "$staging"
echo "packaged $out/${name}.tar.gz"
```

- [ ] **Step 5: Make both executable**

```bash
chmod +x scripts/assert-version.sh scripts/package-tarball.sh
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `scripts/test-release-scripts.sh 2>&1 | tail -5`
Expected: `release-scripts test OK`.

- [ ] **Step 7: Refactor `scripts/release.sh` to use the shared scripts**

Replace the body of `scripts/release.sh` (keep the shebang) with:

```bash
#!/usr/bin/env bash
# Build + package ZigBase release artifacts for all supported targets — the
# MANUAL fallback. The primary path is the `v*` tag → .github/workflows/release.yml,
# which builds once and ships to BOTH the GitHub release and npm. Use this script
# for bootstrap / offline / emergency releases.
# Usage: scripts/release.sh [--publish]   (--publish asserts the version + runs `gh release create`)
set -euo pipefail

cd "$(dirname "$0")/.."
ZIG=(mise exec zig@0.16.0 -- zig)
VERSION="$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
TAG="v${VERSION}"
OUT="dist"
TARGETS=(
  "x86_64-linux-musl"
  "aarch64-linux-musl"
  "x86_64-macos"
  "aarch64-macos"
)

rm -rf "$OUT"
mkdir -p "$OUT"
echo "Building zigbase ${VERSION} for ${#TARGETS[@]} targets (ReleaseSafe)..."
for t in "${TARGETS[@]}"; do
  echo "  -> $t"
  "${ZIG[@]}" build -Dtarget="$t" -Doptimize=ReleaseSafe -Dcpu=baseline
  scripts/package-tarball.sh "$VERSION" "$t" zig-out/bin/zigbase "$OUT"
done

( cd "$OUT" && sha256sum ./*.tar.gz > SHA256SUMS )
echo
echo "Artifacts in $OUT/:"
ls -1 "$OUT"
echo
if [[ "${1:-}" == "--publish" ]]; then
  command -v gh >/dev/null 2>&1 || { echo "gh not found; cannot publish." >&2; exit 1; }
  scripts/assert-version.sh "$VERSION"
  echo "Publishing GitHub release ${TAG}..."
  gh release create "$TAG" "$OUT"/*.tar.gz "$OUT/SHA256SUMS" \
    --title "ZigBase ${VERSION}" \
    --notes-file CHANGELOG.md
  echo "GitHub release done. To publish the npm packages, run:"
  echo "  node clients/typescript/npm/publish.mjs --provenance"
else
  echo "Dry run (no --publish). Primary path: push a 'v${VERSION}' tag → CI releases to GitHub + npm."
fi
```

- [ ] **Step 8: Re-run the test + a release.sh dry run**

Run:
```bash
scripts/test-release-scripts.sh 2>&1 | tail -3
scripts/release.sh 2>&1 | tail -6
```
Expected: `release-scripts test OK`; the dry run builds all four targets, lists the four `dist/zigbase-<ver>-<target>.tar.gz` + `SHA256SUMS`, and prints the "push a v… tag" message. (The build of four cross-targets takes a couple minutes.)

- [ ] **Step 9: Commit**

```bash
git add scripts/assert-version.sh scripts/package-tarball.sh scripts/release.sh scripts/test-release-scripts.sh
git commit -m "feat(release): shared package-tarball + assert-version scripts; release.sh uses them"
```

---

## Task 2: Unified `release.yml`; delete `release-server.yml`; un-dormant `release-sdk.yml`; RELEASING.md

**Files:**
- Create: `.github/workflows/release.yml`
- Delete: `.github/workflows/release-server.yml`
- Modify: `.github/workflows/release-sdk.yml`, `clients/typescript/npm/RELEASING.md`

**Interfaces:**
- Consumes: `scripts/assert-version.sh`, `scripts/package-tarball.sh` (Task 1); `gen-server-packages.mjs` + `publish.mjs` (Plan 2).
- Produces: a `v*` push → GitHub release + `@zigbase/server*` on npm from one build; `typegen-v*` → `@zigbase/typegen`; `client-v*` → `@zigbase/client` (via `release-sdk.yml`).

- [ ] **Step 1: Create `.github/workflows/release.yml`**

```yaml
# Unified project release. Building the zigbase binary ONCE per target and
# shipping it to BOTH the GitHub release (tarballs) and npm (@zigbase/server*).
#
# Triggers:
#   vX.Y.Z       -> build the 4-target matrix once, create the GitHub release
#                   (tarballs + SHA256SUMS), AND publish @zigbase/server* to npm.
#   typegen-vX.Y.Z -> publish @zigbase/typegen (pure JS; no binary build).
#
# The @zigbase/client SDK is released separately via release-sdk.yml (client-v*).
# npm publishing uses OIDC trusted publishing (no token); configure a per-package
# trusted publisher on npmjs.com. See clients/typescript/npm/RELEASING.md.
name: Release

on:
  push:
    tags:
      - "v*"
      - "typegen-v*"

permissions:
  contents: write   # create the GitHub release
  id-token: write   # npm OIDC trusted publishing + provenance

jobs:
  build:
    if: startsWith(github.ref_name, 'v')
    strategy:
      matrix:
        include:
          - key: linux-x64
            zig: x86_64-linux-musl
            runner: ubuntu-latest
          - key: linux-arm64
            zig: aarch64-linux-musl
            runner: ubuntu-latest
          - key: darwin-x64
            zig: x86_64-macos
            runner: macos-latest
          - key: darwin-arm64
            zig: aarch64-macos
            runner: macos-latest
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v7
      - uses: jdx/mise-action@v4
      - name: Assert tag matches build.zig.zon
        run: scripts/assert-version.sh "${GITHUB_REF_NAME#v}"
      - name: Build zigbase (${{ matrix.zig }})
        run: mise exec zig@0.16.0 -- zig build -Dtarget=${{ matrix.zig }} -Doptimize=ReleaseSafe -Dcpu=baseline
      - name: Stage binary
        run: |
          mkdir -p staged
          cp zig-out/bin/zigbase "staged/zigbase"
      - uses: actions/upload-artifact@v7
        with:
          name: zigbase-${{ matrix.key }}
          path: staged/zigbase
          if-no-files-found: error
          retention-days: 1

  github-release:
    if: startsWith(github.ref_name, 'v')
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Assert tag matches build.zig.zon
        run: scripts/assert-version.sh "${GITHUB_REF_NAME#v}"
      - uses: actions/download-artifact@v8
        with: { name: zigbase-linux-x64, path: bin/linux-x64 }
      - uses: actions/download-artifact@v8
        with: { name: zigbase-linux-arm64, path: bin/linux-arm64 }
      - uses: actions/download-artifact@v8
        with: { name: zigbase-darwin-x64, path: bin/darwin-x64 }
      - uses: actions/download-artifact@v8
        with: { name: zigbase-darwin-arm64, path: bin/darwin-arm64 }
      - name: Package tarballs + checksums
        run: |
          version="${GITHUB_REF_NAME#v}"
          mkdir -p dist
          scripts/package-tarball.sh "$version" x86_64-linux-musl  bin/linux-x64/zigbase   dist
          scripts/package-tarball.sh "$version" aarch64-linux-musl bin/linux-arm64/zigbase dist
          scripts/package-tarball.sh "$version" x86_64-macos       bin/darwin-x64/zigbase  dist
          scripts/package-tarball.sh "$version" aarch64-macos      bin/darwin-arm64/zigbase dist
          ( cd dist && sha256sum ./*.tar.gz > SHA256SUMS )
          ls -1 dist
      - name: Create GitHub release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "${GITHUB_REF_NAME}" dist/*.tar.gz dist/SHA256SUMS \
            --title "ZigBase ${GITHUB_REF_NAME#v}" \
            --notes-file CHANGELOG.md

  publish-npm:
    if: startsWith(github.ref_name, 'v')
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v6
        with:
          # node 24 ships npm >= 11.5, required for OIDC trusted publishing.
          node-version: 24
          registry-url: "https://registry.npmjs.org"
      - name: Assert tag matches build.zig.zon
        run: scripts/assert-version.sh "${GITHUB_REF_NAME#v}"
      - name: Generate server package manifests
        run: node clients/typescript/npm/gen-server-packages.mjs
      - name: Download platform binaries into package dirs
        run: |
          for k in linux-x64 linux-arm64 darwin-x64 darwin-arm64; do
            mkdir -p "clients/typescript/npm/server-$k"
          done
      - uses: actions/download-artifact@v8
        with: { name: zigbase-linux-x64, path: clients/typescript/npm/server-linux-x64 }
      - uses: actions/download-artifact@v8
        with: { name: zigbase-linux-arm64, path: clients/typescript/npm/server-linux-arm64 }
      - uses: actions/download-artifact@v8
        with: { name: zigbase-darwin-x64, path: clients/typescript/npm/server-darwin-x64 }
      - uses: actions/download-artifact@v8
        with: { name: zigbase-darwin-arm64, path: clients/typescript/npm/server-darwin-arm64 }
      - name: chmod binaries
        run: chmod +x clients/typescript/npm/server-*/zigbase
      - name: Publish server packages (platform → meta) with provenance
        run: node clients/typescript/npm/publish.mjs --skip-build --provenance --what server

  publish-typegen:
    if: startsWith(github.ref_name, 'typegen-v')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v6
        with:
          node-version: 24
          registry-url: "https://registry.npmjs.org"
      - name: Assert @zigbase/typegen version matches the tag
        run: |
          tag="${GITHUB_REF_NAME}"; expected="${tag#typegen-v}"
          actual="$(node -p "require('./clients/typescript/npm/typegen/package.json').version")"
          echo "tag=$tag expected=$expected pkg=$actual"
          [ "$expected" = "$actual" ] || { echo "::error::tag $tag != @zigbase/typegen version $actual"; exit 1; }
      - name: Publish @zigbase/typegen with provenance
        run: node clients/typescript/npm/publish.mjs --skip-build --provenance --what typegen
```

- [ ] **Step 2: Delete the old server workflow**

```bash
git rm .github/workflows/release-server.yml
```

- [ ] **Step 3: Un-dormant `release-sdk.yml`**

In `.github/workflows/release-sdk.yml`, replace the long "DORMANT" header comment block (lines 1–25, from `# ---` through the closing `# ---`) with:

```yaml
# TypeScript SDK release: publishes @zigbase/client to npm on a `client-v*` tag.
# The SDK is versioned INDEPENDENTLY of the server (which uses `vX.Y.Z` tags).
# Publishes via OIDC trusted publishing (no token) — a per-package trusted
# publisher for this workflow must be configured on npmjs.com.
# See clients/typescript/RELEASING.md.
```

Then make its version guard use the shared script — replace the `Assert package.json version matches the tag` step's `run:` block with a call that still reads the SDK's own `package.json` (the SDK version is NOT in build.zig.zon, so it keeps its inline check). Leave that step as-is (it already correctly compares `package.json` to the `client-v` tag); only the header comment changes.

- [ ] **Step 4: Validate the workflow YAML**

Run:
```bash
for f in .github/workflows/release.yml .github/workflows/release-sdk.yml; do
  python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1])); print('YAML OK', sys.argv[1])" "$f"
done
# actionlint if available (don't fail the task if it isn't installed):
command -v actionlint >/dev/null 2>&1 && actionlint .github/workflows/release.yml || echo "(actionlint not installed — skipped)"
```
Expected: both `YAML OK`; actionlint clean or skipped.

- [ ] **Step 5: Verify the workflow references the shared scripts + folds the tag**

Run:
```bash
grep -q "scripts/assert-version.sh" .github/workflows/release.yml && echo "guard wired OK"
grep -q "scripts/package-tarball.sh" .github/workflows/release.yml && echo "packaging wired OK"
grep -rq "server-v" .github/workflows/ && echo "!! server-v STILL referenced" || echo "server-v removed OK"
test ! -f .github/workflows/release-server.yml && echo "release-server.yml deleted OK"
echo "triggers in release.yml:"; grep -A3 "tags:" .github/workflows/release.yml | head -5
```
Expected: `guard wired OK`, `packaging wired OK`, `server-v removed OK`, `release-server.yml deleted OK`, and the triggers show `v*` + `typegen-v*`.

- [ ] **Step 6: Rewrite `clients/typescript/npm/RELEASING.md`**

Replace the "Normal releases — OIDC" + "Bumping versions" sections so they describe the unified flow. The new content must state:
- **Server / project release:** bump `build.zig.zon` `.version` (one line) → commit → `git tag vX.Y.Z` → `git push --follow-tags`. CI builds once and ships to the GitHub release + `@zigbase/server*`. The five server `package.json`s are GENERATED from `targets.json` + `build.zig.zon` (Plan 2) — do not edit them.
- **Typegen release:** bump `clients/typescript/npm/typegen/package.json` → `git tag typegen-vX.Y.Z` → push.
- **Client release:** bump `clients/typescript/package.json` → `git tag client-vX.Y.Z` → push (`release-sdk.yml`).
- A CI version guard asserts the tag matches `build.zig.zon` (`v*`) or the package's `package.json` (`typegen-v*`/`client-v*`).
- The manual fallback `scripts/release.sh --publish` builds + packages + creates the GitHub release; npm is then `node clients/typescript/npm/publish.mjs --provenance`.
Keep the "Package dependency order" and "Script reference" sections; update any `server-vX.Y.Z` mention to `vX.Y.Z`.

- [ ] **Step 7: Stale-reference sweep**

Run:
```bash
grep -rn "server-v" .github/ clients/typescript/npm/RELEASING.md docs/*.md 2>/dev/null | grep -v "docs/superpowers" || echo "NO server-v REFERENCES"
```
Expected: `NO server-v REFERENCES` (the spec/plan docs under `docs/superpowers/` may still mention the history).

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/release.yml .github/workflows/release-sdk.yml clients/typescript/npm/RELEASING.md
git rm .github/workflows/release-server.yml 2>/dev/null || true
git commit -m "ci(release): unified v* build-once pipeline (GitHub + npm); retire server-v*; document flow"
```

---

## Notes for the executor

- Workflow logic cannot be exercised without cutting a real release; verification here is YAML validity + actionlint + the Task-1 shell tests + review. The genuine end-to-end is the Plan-4 follow-up that cuts `v0.4.1`.
- Both `github-release` and `publish-npm` consume the SAME artifacts from the single `build` matrix — that is the "build once → both channels" property; do not add a second build.
- The `v*` trigger also matches `vX.Y.Z` but NOT `client-v*`/`typegen-v*` (those don't start with `v` followed by a digit — `client-v`/`typegen-v` start with `c`/`t`). The `typegen-v*` trigger is explicit; `client-v*` lives in `release-sdk.yml`. (If desired, the executor may tighten the `v*` filter to `v[0-9]*` for clarity — note it in the report.)
