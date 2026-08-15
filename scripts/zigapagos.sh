#!/usr/bin/env bash
set -euo pipefail

# Keep every local, CI, and example build on the published migration target.
# npx's explicit package version also supplies Zigapagos's pinned Bun runtime.
exec npx --yes --package zigapagos@0.4.0 -- zigapagos "$@"
