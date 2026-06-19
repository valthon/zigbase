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
