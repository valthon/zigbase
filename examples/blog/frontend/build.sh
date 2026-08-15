#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

exec ../../../scripts/zigapagos.sh release \
  --force \
  --output=dist \
  --island-props-check=error \
  --island=components/AuthStatus.island.tsx \
  --island=components/Editor.island.tsx \
  --island=components/PostList.island.tsx \
  --island=components/PostView.island.tsx \
  "$@"
