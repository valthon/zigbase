#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 STOCK_DEBUG_BINARY IDEMPOTENCY_FIXTURE" >&2
  exit 2
fi
# Unstripped Debug builds provide a positive control for Zig lazy compilation.
stock_symbols=$(nm "$1")
enabled_symbols=$(nm "$2")
if [[ "$stock_symbols" == *idempotency.Idempotency* ]]; then
  echo "unused idempotency execution leaked into stock binary" >&2
  exit 1
fi
if [[ "$enabled_symbols" != *idempotency.Idempotency* ]]; then
  echo "positive control lacks idempotency execution symbols" >&2
  exit 1
fi
