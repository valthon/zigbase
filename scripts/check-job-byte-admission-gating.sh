#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'usage: check-job-byte-admission-gating.sh BYTE_ONLY_BINARY SHARED_BINARY' >&2
  exit 2
fi
bytes=$(nm --defined-only "$1")
shared=$(nm --defined-only "$2")
# Anchor at the end: acquireJobBytes/releaseJobBytes are intentionally present.
for pattern in 'admission\.State\.acquire$' 'admission\.State\.release$'; do
  if grep -E "$pattern" <<< "$bytes" >/dev/null; then
    echo "LEAK: byte-only build retains $pattern" >&2; exit 1
  fi
  if ! grep -E "$pattern" <<< "$shared" >/dev/null; then
    echo "DRIFT: shared build lacks $pattern" >&2; exit 1
  fi
done
for pattern in 'admission\.State\.acquireJobBytes$' 'admission\.State\.releaseJobBytes$'; do
  if ! grep -E "$pattern" <<< "$bytes" >/dev/null; then
    echo "DRIFT: byte-only build lacks $pattern" >&2; exit 1
  fi
done
echo 'byte-only admission gating: OK (no HTTP permits; job byte accounting present)'
