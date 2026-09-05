#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# The generated facade imports the local SDK package. Prepare it even when
# this script is the first command in a fresh checkout (including CI's Zig
# build job, which runs before the TypeScript job).
# The running test harness must never replace its own node_modules tree.
# --no-install requires dependencies and SDK output to be prepared before Vitest
# starts. Rebuilding the SDK would also clean modules the test runner imports.
if [[ "${1:-}" == "--no-install" ]]; then
  shift
else
  npm --prefix ../../../clients/typescript ci
  npm --prefix ../../../clients/typescript run build
  npm --prefix .. install
fi
npm --prefix .. run typecheck

exec ../../../scripts/zigapagos.sh release \
  --force \
  --output=dist \
  --island-props-check=error \
  --island=src/components/ListingsBrowser.island.tsx \
  --island=src/components/MyBookings.island.tsx \
  --format=json \
  "$@"
