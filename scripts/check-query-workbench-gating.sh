#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'usage: check-query-workbench-gating.sh OFF_BINARY ON_BINARY' >&2
  exit 2
fi
off=$(nm --defined-only "$1")
on=$(nm --defined-only "$2")
for pattern in 'query_workbench\.Measurement\.' 'query_workbench\.Lifetime\.' 'query_workbench\.Scope\.' 'query_workbench\.Store\.' 'query_workbench\.current' 'query_workbench\.serial'; do
  if grep -E "$pattern" <<< "$off" >/dev/null; then
    echo "LEAK: $pattern" >&2; exit 1
  fi
  if ! grep -E "$pattern" <<< "$on" >/dev/null; then
    echo "DRIFT: $pattern" >&2; exit 1
  fi
done
echo 'query workbench gating: OK (6 paired patterns)'
