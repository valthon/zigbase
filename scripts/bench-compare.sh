#!/usr/bin/env bash
# Build and run the bench harness at two revisions and print ns/op + alloc deltas.
# Report-only: this never fails on a regression (see the allocator-ownership spec —
# shared runners are too noisy for a threshold gate).
set -euo pipefail
cd "$(dirname "$0")/.."

A="${1:?usage: bench-compare.sh <rev-a> <rev-b>}"
B="${2:?usage: bench-compare.sh <rev-a> <rev-b>}"
ZIG=(mise exec zig@0.16.0 -- zig)
tmp="$(mktemp -d)"

# Worktree paths this script has created, so the EXIT trap can force-remove
# every one of them even if we die partway through the loop (e.g. `zig build
# bench` fails under `set -e`, or the script is interrupted). Without this,
# `rm -rf "$tmp"` deletes the directory but leaves the worktree registered in
# the shared repo's .git/worktrees, requiring a manual `git worktree prune`.
created_worktrees=()

cleanup() {
  local wt
  for wt in "${created_worktrees[@]+"${created_worktrees[@]}"}"; do
    git worktree remove --force "$wt" >/dev/null 2>&1 || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

# Run a git command quietly on success, but surface its output on failure
# instead of swallowing the diagnostic (e.g. "invalid reference: <rev>").
git_quiet() {
  local out
  if ! out="$(git "$@" 2>&1)"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
}

# ONE definition of the ref->filename mapping, used for both the write (in the
# loop) and the read (the python invocation), so the two can never disagree —
# the bug this replaces derived the write path via tr on the full ref but the
# read path via basename-then-tr, which only match when $rev has no "/" (i.e.
# is not a branch like "chore/allocator-discipline").
#
# Deliberately NOT an associative array: `declare -A` is bash 4+, and macOS
# still ships bash 3.2. This repo supports macOS, so the script stays 3.2-clean.
json_for() { printf '%s/%s.json' "$tmp" "$(printf '%s' "$1" | tr '/' '_')"; }
wt_for() { printf '%s/%s' "$tmp" "$(printf '%s' "$1" | tr '/' '_')"; }

for rev in "$A" "$B"; do
  wt="$(wt_for "$rev")"
  json="$(json_for "$rev")"

  created_worktrees+=("$wt")
  git_quiet worktree add --detach "$wt" "$rev"
  ( cd "$wt" && "${ZIG[@]}" build bench -- --json ) > "$json"
  git_quiet worktree remove --force "$wt"
  # It's already gone; leaving it in created_worktrees is harmless — the
  # trap's removal is best-effort (errors suppressed) and a second attempt
  # against an already-removed path is a silent no-op failure.
done

python3 - "$(json_for "$A")" "$(json_for "$B")" <<'PY'
import json, sys
def load(p):
    out = {}
    for line in open(p):
        line = line.strip()
        if line:
            r = json.loads(line)
            out[r["name"]] = r
    return out
a, b = load(sys.argv[1]), load(sys.argv[2])
print(f"{'benchmark':<34}{'ns/op A':>10}{'ns/op B':>10}{'delta':>9}{'allocs A':>10}{'allocs B':>10}")
for name in sorted(set(a) | set(b)):
    ra, rb = a.get(name), b.get(name)
    if not ra or not rb:
        print(f"{name:<34}{'(only in one revision)':>49}")
        continue
    d = (rb["ns_median"] - ra["ns_median"]) / ra["ns_median"] * 100 if ra["ns_median"] else 0.0
    print(f"{name:<34}{ra['ns_median']:>10}{rb['ns_median']:>10}{d:>8.1f}%{ra['allocs']:>10}{rb['allocs']:>10}")
PY
