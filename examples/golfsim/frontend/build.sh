#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

exec ../../../scripts/zigapagos.sh release \
  --force \
  --output=dist \
  --island-props-check=error \
  --island=src/components/ListingsBrowser.island.tsx \
  --island=src/components/MyBookings.island.tsx \
  --format=json \
  "$@"
