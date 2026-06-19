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
