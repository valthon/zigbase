#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'usage: check-public-response-cache-gating.sh OFF_BINARY ON_BINARY' >&2
  exit 2
fi
off=$(nm --defined-only "$1")
on=$(nm --defined-only "$2")
for pattern in 'public_response_cache\.Store\.' 'public_response_cache\.Stamp\.' 'public_response_cache\.view'; do
  if grep -E "$pattern" <<< "$off" >/dev/null; then
    echo "LEAK: $pattern" >&2; exit 1
  fi
  if ! grep -E "$pattern" <<< "$on" >/dev/null; then
    echo "DRIFT: $pattern" >&2; exit 1
  fi
done
echo 'public response cache gating: OK (3 paired patterns)'
