#!/usr/bin/env bash
# Build + package ZigBase release artifacts for all supported targets — the
# MANUAL fallback. The primary path is the `v*` tag → .github/workflows/release.yml,
# which builds once and ships to BOTH the GitHub release and npm. Use this script
# for bootstrap / offline / emergency releases.
# Usage: scripts/release.sh [--publish]   (--publish asserts the version + runs `gh release create`)
set -euo pipefail

cd "$(dirname "$0")/.."
ZIG=(mise exec zig@0.16.0 -- zig)
VERSION="$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | cut -d'"' -f2)"
TAG="v${VERSION}"
OUT="dist"
TARGETS=(
  "x86_64-linux-musl"
  "aarch64-linux-musl"
  "x86_64-macos"
  "aarch64-macos"
)

# Assemble changelog fragments (changelog.d/*.md) into a `## [${VERSION}] - <date>` section
# of CHANGELOG.md + its site mirror, then delete them. See changelog.d/README.md. Skipped
# (not an error) when there are no fragments — e.g. the changelog was already assembled.
shopt -s nullglob
frags=(changelog.d/*.md)
shopt -u nullglob
have_frags=0
for f in "${frags[@]}"; do [[ "${f##*/}" == "README.md" ]] || have_frags=1; done
if [[ "$have_frags" == 1 ]]; then
  echo "Assembling changelog fragments into ${VERSION}..."
  scripts/assemble-changelog.sh "$VERSION"
else
  echo "No changelog fragments to assemble (changelog already finalized for ${VERSION})."
fi

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
