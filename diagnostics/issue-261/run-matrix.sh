#!/usr/bin/env bash
set -u

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
zig_bin="${ZIG_BIN:-zig}"
runs="${RUNS:-50}"
load_workers="${LOAD_WORKERS:-0}"
results_dir="${RESULTS_DIR:-$(mktemp -d /tmp/zigbase-issue261-results.XXXXXX)}"
global_cache="${ZIG_GLOBAL_CACHE_DIR:-/tmp/zigbase-issue261-global-cache}"
load_pids=()

cleanup() {
    for pid in "${load_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

mkdir -p "$results_dir"
if (( load_workers > 0 )); then
    for ((i = 0; i < load_workers; i++)); do
        yes > /dev/null &
        load_pids+=("$!")
    done
fi

run_case() {
    local label="$1"
    shift
    local exit_failures=0
    local warning_blocks=0

    for ((i = 1; i <= runs; i++)); do
        local log="$results_dir/$label-$i.log"
        ZIG_GLOBAL_CACHE_DIR="$global_cache" "$zig_bin" build test "$@" --summary all >"$log" 2>&1
        local rc=$?
        if (( rc != 0 )); then
            ((exit_failures += 1))
        fi
        if grep -Eq '^failed command: .*--listen=-' "$log"; then
            ((warning_blocks += 1))
        fi
        printf '%d\t%d\n' "$i" "$rc" >>"$results_dir/$label-status.tsv"
    done

    printf '%s runs=%d failed-command-lines=%d nonzero-exits=%d\n' \
        "$label" "$runs" "$warning_blocks" "$exit_failures"
}

cd "$script_dir"
run_case native
run_case baseline -Dcpu=baseline
printf 'logs=%s\n' "$results_dir"
