#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/zigbase"
cp -R zig-out/site/. "$ROOT/zigbase/"
../scripts/zigapagos.sh e2e --site="$ROOT" --ready-path=/zigbase/ -- python3 test/browser.py
