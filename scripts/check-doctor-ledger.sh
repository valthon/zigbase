#!/usr/bin/env bash
# Frozen doctor check-id ledger (SP-3, docs/serve.md).
#
# `src/doctor_ids.txt` is APPEND-ONLY: a shipped check id is a contract a script
# may match on forever, so ids may be added but never renamed, reordered, or
# removed. src/doctor.zig's own test proves the ledger and the registry agree;
# only a diff against the base branch can prove the ledger never loses a line.
#
# Removing an id is a deliberate breaking change: delete this check's exemption
# by editing the script, in the same PR, with the reason.
set -euo pipefail
cd "$(dirname "$0")/.."

LEDGER=src/doctor_ids.txt
BASE="${1:-origin/main}"

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "doctor ledger: base ref '$BASE' is unavailable; skipping the append-only check."
  echo "  (CI fetches it; locally, run 'git fetch origin main' to enable this check.)"
  exit 0
fi

# `git merge-base` exits 1 SILENTLY (documented behavior, no stderr) when the
# two histories share no fetched ancestor — which under `set -e` used to abort
# this script with zero diagnostics. That is exactly what happens in a shallow
# CI checkout whose fetch deepened only the base ref and not HEAD's own
# ancestry. Fail LOUDLY with the remedy instead: a silent skip here would
# disable the append-only check in the one place it matters, and a silent
# exit 1 is undebuggable from a CI log.
if ! merge_base=$(git merge-base "$BASE" HEAD 2>/dev/null); then
  echo "ERROR: doctor ledger: cannot compute merge-base('$BASE', HEAD) — no common"
  echo "  ancestor is reachable, almost always because this is a SHALLOW clone whose"
  echo "  fetch did not include the fork point. Deepen both sides, e.g.:"
  echo "    git fetch --no-tags origin main && git fetch --no-tags --deepen=200 origin"
  exit 1
fi
# Compare the ledger as of the merge base with the ledger now. Every line that
# existed then must still exist now, at the same index.
old=$(git show "$merge_base:$LEDGER" 2>/dev/null || true)
if [ -z "$old" ]; then
  echo "doctor ledger: no ledger at the merge base — this PR introduces it. OK."
  exit 0
fi

fail=0
i=0
while IFS= read -r line; do
  i=$((i + 1))
  now=$(sed -n "${i}p" "$LEDGER")
  if [ "$now" != "$line" ]; then
    echo "ERROR: $LEDGER line $i changed from '$line' to '${now:-<missing>}'."
    echo "  Check ids are frozen once shipped. Append new ids at the END; never"
    echo "  rename, reorder, or remove one."
    fail=1
  fi
done <<< "$old"

if [ "$fail" -ne 0 ]; then
  echo "doctor ledger: append-only invariant violated"
  exit 1
fi
echo "doctor ledger: OK ($(wc -l < "$LEDGER") ids, $i unchanged)"
