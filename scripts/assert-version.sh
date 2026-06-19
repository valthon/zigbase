#!/usr/bin/env bash
# Assert that <expected> matches build.zig.zon's .version (the single source of truth).
# Usage: scripts/assert-version.sh <expected-version>
set -euo pipefail
cd "$(dirname "$0")/.."
expected="${1:?usage: assert-version.sh <expected-version>}"
actual="$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | cut -d'"' -f2)"
echo "expected=$expected build.zig.zon=$actual"
if [ "$expected" != "$actual" ]; then
  echo "::error::version mismatch: tag implies $expected but build.zig.zon has $actual" >&2
  exit 1
fi
