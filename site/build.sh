#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

node --experimental-strip-types scripts/gen-content.ts
../scripts/zigapagos.sh validate --format=json
../scripts/zigapagos.sh release --force --output="$PWD/zig-out/site"
