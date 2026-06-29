#!/usr/bin/env bash
# Extract a single version's changelog section from CHANGELOG.md and print it to stdout.
# Usage: scripts/extract-release-notes.sh <version>
#   <version>  The version to extract (e.g. "0.8.0" or "v0.8.0"; leading "v" is stripped).
# Exits non-zero if the version is not found.
# Output: everything from the "## [<version>]" header line through (but not including) the
# next "## [" header — i.e. the complete section including sub-headings like ### Features.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>" >&2
  exit 1
fi
# Strip a leading "v" so both "0.8.0" and "v0.8.0" work.
VERSION="${VERSION#v}"

CHANGELOG="$(dirname "$0")/../CHANGELOG.md"
if [[ ! -f "$CHANGELOG" ]]; then
  echo "error: CHANGELOG.md not found at $CHANGELOG" >&2
  exit 1
fi

# awk logic:
#   found=0  — set to 1 when we hit the target "## [VERSION]" header line.
#   After setting found=1 we print lines until the next "## [" line (exclusive).
#   If found is never set, exit non-zero.
awk -v ver="$VERSION" '
  /^## \[/ {
    if (found) exit          # next version header: we are done
    if (index($0, "## [" ver "]") == 1) { found=1 }
  }
  found { print }
  END { if (!found) { print "error: version " ver " not found in CHANGELOG.md" > "/dev/stderr"; exit 1 } }
' "$CHANGELOG"
