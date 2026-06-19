#!/usr/bin/env bash
# Package one target's zigbase binary into a release tarball:
#   <out>/zigbase-<version>-<target>.tar.gz  containing
#   zigbase-<version>-<target>/{zigbase,LICENSE,README.md,KNOWN_LIMITATIONS.md}
# Usage: scripts/package-tarball.sh <version> <target> <binary-path> <out-dir>
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?version}"; target="${2:?target}"; binary="${3:?binary}"; out="${4:?out-dir}"
mkdir -p "$out"
out_abs="$(cd "$out" && pwd)"   # absolute path so `tar -C` is robust across GNU/BSD tar
name="zigbase-${version}-${target}"
staging="$out_abs/$name"
mkdir -p "$staging"
cp "$binary" "$staging/zigbase"
chmod +x "$staging/zigbase"
cp LICENSE README.md KNOWN_LIMITATIONS.md "$staging/"
tar -czf "$out_abs/${name}.tar.gz" -C "$out_abs" "$name"
rm -rf "$staging"
echo "packaged $out_abs/${name}.tar.gz"
