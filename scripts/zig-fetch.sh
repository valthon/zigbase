#!/usr/bin/env bash
# Fetch the Zig package tree (zap from GitHub; translate-c and its arocc
# dependency from Codeberg) before any build step, retrying transient failures.
#
# Zig 0.17.1 fetches git+https dependencies during `zig build` configuration and
# reports a non-200 from the remote's smart-HTTP endpoint only as
# "unable to discover remote git server capabilities: ProtocolError". Without a
# restored package cache, every CI job fetches from Codeberg concurrently; one
# failed request fails the job. Fetching once, up front and with retries, turns
# a transient remote failure into a delay. Later `zig build` invocations, in the
# repo root or in examples/* (path dependency on the root), find the packages in
# ./zig-pkg or in $ZIG_GLOBAL_CACHE_DIR/p and do not touch the network.
#
# Usage: scripts/zig-fetch.sh [attempts]   (default 4; waits 15-29s, 30-59s, 60-119s between)
set -euo pipefail
cd "$(dirname "$0")/.."
attempts="${1:-4}"
if ! [[ "$attempts" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: scripts/zig-fetch.sh [attempts >= 1]" >&2
  exit 2
fi
delay=15
for ((i = 1; i <= attempts; i++)); do
  if mise exec zig@0.17.1 -- zig build --fetch; then
    exit 0
  fi
  if ((i == attempts)); then
    echo "::error::zig build --fetch failed after ${attempts} attempts" >&2
    exit 1
  fi
  # Jitter: cold-cache jobs start together; spread their retries apart.
  wait=$((delay + RANDOM % delay))
  echo "::warning::zig build --fetch failed (attempt ${i}/${attempts}); retrying in ${wait}s" >&2
  sleep "${wait}"
  delay=$((delay * 2))
done
