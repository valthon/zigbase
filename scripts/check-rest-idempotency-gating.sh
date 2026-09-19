#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'usage: check-rest-idempotency-gating.sh OFF_BINARY ON_BINARY' >&2
  exit 2
fi
off=$(nm --defined-only "$1")
on=$(nm --defined-only "$2")
pattern='rest_idempotency\.Implementation.*\.(attempt|authorizeReplay)'
if grep -E "$pattern" <<< "$off" >/dev/null; then
  echo 'REST receipt implementation leaked into disabled binary' >&2
  exit 1
fi
if ! grep -E "$pattern" <<< "$on" >/dev/null; then
  echo 'Enabled REST receipt implementation missing' >&2
  exit 1
fi
echo 'REST receipt implementation gating: OK'
