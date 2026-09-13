#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'usage: check-shared-admission-gating.sh OFF_BINARY ON_BINARY' >&2
  exit 2
fi
off=$(nm --defined-only "$1")
on=$(nm --defined-only "$2")
for pattern in 'admission\.State\.acquireJob' 'admission\.State\.releaseJob'; do
  if grep -E "$pattern" <<< "$off" >/dev/null; then
    echo "LEAK: $pattern" >&2; exit 1
  fi
  if ! grep -E "$pattern" <<< "$on" >/dev/null; then
    echo "DRIFT: $pattern" >&2; exit 1
  fi
done
echo 'shared admission gating: OK (2 paired patterns)'
