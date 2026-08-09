#!/usr/bin/env bash
# Frozen error-code ledger (SP-1, docs/observability.md).
#
# `src/error-codes.frozen` is APPEND-ONLY: a shipped error code is a string that
# agents and SDKs switch on forever, so codes may be added, and may be RETIRED
# (moved from [ACTIVE] to [RETIRED]), but a name must never vanish and must never
# be reused for a different meaning.
#
# src/error_codes.zig's own tests prove the enum and [ACTIVE] agree, that [ACTIVE]
# is sorted and duplicate-free, and that no enum field reuses a [RETIRED] name.
# None of them can see HISTORY: deleting a code from BOTH the enum and [ACTIVE] in
# one commit passes every one of them. Only a diff against the base branch catches
# that, which is what this script is for.
#
# This is the SET-DIFFERENCE sibling of scripts/check-doctor-ledger.sh. That ledger
# is positional (append at the end, compare line N to line N); this one is
# alphabetically sorted, so a new code legitimately lands anywhere in the file and
# only set membership is invariant.
#
# Retiring a code is the sanctioned path and needs no exemption: move its line from
# [ACTIVE] to [RETIRED] and delete the enum field. Deleting the line outright is a
# breaking change to every consumer matching on it — if you truly mean to, edit this
# script in the same PR with the reason.
set -euo pipefail
cd "$(dirname "$0")/.."

LEDGER=src/error-codes.frozen

# Print one `[SECTION]`'s codes, one per line: blank lines and `#` comments dropped,
# surrounding whitespace trimmed. Reads the ledger CONTENT on stdin, so it works
# identically on the working tree and on a `git show` of some other commit.
section() {
  awk -v want="[$1]" '
    $0 == want { inside = 1; next }
    /^\[/      { inside = 0 }
    inside {
      sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, "")
      if ($0 == "" || substr($0, 1, 1) == "#") next
      print
    }'
}

has() { printf '%s\n' "$2" | grep -Fxq -- "$1"; }

# The pure core: given the ledger's OLD and NEW contents, report every append-only
# violation. No git, no filesystem — so `--self-test` below can exercise it directly.
# Returns 0 when the new ledger is a legal successor of the old one.
compare_ledgers() {
  local old_content="$1" new_content="$2" fail=0
  local old_active old_retired new_active new_retired
  old_active=$(printf '%s\n' "$old_content" | section ACTIVE)
  old_retired=$(printf '%s\n' "$old_content" | section RETIRED)
  new_active=$(printf '%s\n' "$new_content" | section ACTIVE)
  new_retired=$(printf '%s\n' "$new_content" | section RETIRED)

  # 1. An ACTIVE code may stay ACTIVE or become RETIRED. It may never disappear.
  while IFS= read -r code; do
    [ -n "$code" ] || continue
    if ! has "$code" "$new_active" && ! has "$code" "$new_retired"; then
      echo "ERROR: error code '$code' was removed from $LEDGER."
      echo "  Codes are frozen once shipped. To stop emitting one, MOVE its line to"
      echo "  [RETIRED] and delete the enum field — the line itself never disappears."
      fail=1
    fi
  done <<< "$old_active"

  # 2. A RETIRED code stays retired forever: dropping the line loses the tombstone
  #    that stops the name being reused, and moving it back to [ACTIVE] IS the reuse.
  while IFS= read -r code; do
    [ -n "$code" ] || continue
    if has "$code" "$new_active"; then
      echo "ERROR: error code '$code' moved from [RETIRED] back to [ACTIVE] in $LEDGER."
      echo "  A retired name is never reused — its old meaning is still in the wild."
      echo "  Pick a new name instead."
      fail=1
    elif ! has "$code" "$new_retired"; then
      echo "ERROR: retired error code '$code' was deleted from $LEDGER."
      echo "  A [RETIRED] line is a permanent tombstone; it must never be removed."
      fail=1
    fi
  done <<< "$old_retired"

  return "$fail"
}

# Fixture-driven proof that the core actually bites. Runs in CI beside the real
# check, so the guard cannot silently rot into a no-op that always passes.
self_test() {
  local base allowed_add allowed_retire deleted resurrected tombstone_dropped rc fails=0
  base=$'[ACTIVE]\nbad_request\nnot_found\n\n[RETIRED]\nold_code\n'
  allowed_add=$'[ACTIVE]\nbad_request\nconflict\nnot_found\n\n[RETIRED]\nold_code\n'
  allowed_retire=$'[ACTIVE]\nbad_request\n\n[RETIRED]\nnot_found\nold_code\n'
  deleted=$'[ACTIVE]\nbad_request\n\n[RETIRED]\nold_code\n'
  resurrected=$'[ACTIVE]\nbad_request\nnot_found\nold_code\n\n[RETIRED]\n'
  tombstone_dropped=$'[ACTIVE]\nbad_request\nnot_found\n\n[RETIRED]\n'

  expect() { # name, expected_rc, old, new
    local name="$1" want="$2"
    if compare_ledgers "$3" "$4" >/dev/null 2>&1; then rc=0; else rc=1; fi
    if [ "$rc" -ne "$want" ]; then
      echo "SELF-TEST FAIL: $name expected rc=$want, got rc=$rc"
      fails=1
    fi
  }

  expect "adding a code is allowed"            0 "$base" "$allowed_add"
  expect "retiring a code is allowed"          0 "$base" "$allowed_retire"
  expect "no change is allowed"                0 "$base" "$base"
  expect "DELETING an active code is caught"   1 "$base" "$deleted"
  expect "resurrecting a retired code"         1 "$base" "$resurrected"
  expect "dropping a retired tombstone"        1 "$base" "$tombstone_dropped"

  if [ "$fails" -ne 0 ]; then
    echo "error-code ledger: SELF-TEST FAILED — the guard does not catch what it claims"
    exit 1
  fi
  echo "error-code ledger: self-test OK (6 cases)"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

BASE="${1:-origin/main}"
self_test

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "error-code ledger: base ref '$BASE' is unavailable; skipping the append-only check."
  echo "  (CI fetches it; locally, run 'git fetch origin main' to enable this check.)"
  exit 0
fi

# `git merge-base` exits 1 SILENTLY when the two histories share no fetched
# ancestor — exactly what a shallow CI checkout produces when the fetch deepened
# only the base ref and not HEAD's own ancestry. Under `set -e` that aborts this
# script with zero diagnostics, disabling the check in the one place it matters.
# Fail LOUDLY with the remedy instead. (Same failure SP-3's doctor ledger hit.)
if ! merge_base=$(git merge-base "$BASE" HEAD 2>/dev/null); then
  echo "ERROR: error-code ledger: cannot compute merge-base('$BASE', HEAD) — no common"
  echo "  ancestor is reachable, almost always because this is a SHALLOW clone whose"
  echo "  fetch did not include the fork point. Deepen both sides, e.g.:"
  echo "    git fetch --no-tags origin main && git fetch --no-tags --deepen=200 origin"
  exit 1
fi

old=$(git show "$merge_base:$LEDGER" 2>/dev/null || true)
if [ -z "$old" ]; then
  echo "error-code ledger: no ledger at the merge base — this PR introduces it. OK."
  exit 0
fi

new=$(cat "$LEDGER")
if ! compare_ledgers "$old" "$new"; then
  echo "error-code ledger: append-only invariant violated"
  exit 1
fi

active_count=$(printf '%s\n' "$new" | section ACTIVE | grep -c . || true)
retired_count=$(printf '%s\n' "$new" | section RETIRED | grep -c . || true)
echo "error-code ledger: OK ($active_count active, $retired_count retired, none lost since $merge_base)"
