#!/usr/bin/env bash
# Build + package ZigBase release artifacts for all supported targets.
# Usage: scripts/release.sh [--publish]   (--publish runs `gh release create` for the version tag)
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
echo "Building zigbase ${VERSION} for ${#TARGETS[@]} targets..."
for t in "${TARGETS[@]}"; do
  echo "  -> $t"
  "${ZIG[@]}" build -Dtarget="$t" -Doptimize=ReleaseSafe
  name="zigbase-${VERSION}-${t}"
  staging="$OUT/$name"
  mkdir -p "$staging"
  cp zig-out/bin/zigbase "$staging/zigbase"
  cp LICENSE README.md KNOWN_LIMITATIONS.md "$staging/"
  tar -czf "$OUT/${name}.tar.gz" -C "$OUT" "$name"
  rm -rf "$staging"
done

( cd "$OUT" && sha256sum ./*.tar.gz > SHA256SUMS )
echo
echo "Artifacts in $OUT/:"
ls -1 "$OUT"
echo
if [[ "${1:-}" == "--publish" ]]; then
  if ! command -v gh >/dev/null 2>&1; then echo "gh not found; cannot publish." >&2; exit 1; fi
  echo "Publishing GitHub release ${TAG}..."
  gh release create "$TAG" "$OUT"/*.tar.gz "$OUT/SHA256SUMS" \
    --title "ZigBase ${VERSION}" \
    --notes-file CHANGELOG.md
else
  echo "Dry run (no --publish). To publish: scripts/release.sh --publish"
  echo "(requires a GitHub remote + 'gh auth login'; the tag ${TAG} should exist or gh will create it from HEAD)"
fi
