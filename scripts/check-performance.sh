#!/usr/bin/env bash
# Opt-in measured example: emit one versioned JSON report, never gate timings.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 0 && ( $# != 2 || "$1" != --baseline ) ]]; then
  echo 'usage: bash scripts/check-performance.sh [--baseline report.json]' >&2
  exit 2
fi
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo 'The example contract is calibrated for x86_64 Linux; use the Python CLI with your own contract.' >&2
  exit 2
fi
perf_tmp="$(mktemp -d)"
trap 'rm -rf "$perf_tmp"' EXIT
if [[ "$(zig version)" != 0.16.0 ]]; then
  echo 'Performance contract example requires Zig 0.16.0 on PATH.' >&2
  exit 2
fi
zig build -Dtarget=x86_64-linux-gnu -Dcpu=baseline -Doptimize=ReleaseSmall -Ddev-tools=false -p "$perf_tmp/install" >&2
zig build bench -Dtarget=x86_64-linux-gnu -Dcpu=baseline -Dbench-optimize=ReleaseFast -- --json > "$perf_tmp/bench.jsonl"
python3 tools/performance_contracts.py --contract bench/contracts/release-small-linux.json --binary "$perf_tmp/install/bin/zigbase" --benchmarks "$perf_tmp/bench.jsonl" "$@"
