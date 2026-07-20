#!/usr/bin/env bash
# Allocator-ownership ratchet (see docs/superpowers/specs/2026-07-19-allocator-ownership-design.md).
#
# Wrapping `std.testing.allocator` in an arena DISABLES Zig's leak detector for that
# test. That is legitimate only when the code under test takes `RequestArena`
# (contract 4). This check does not try to prove that statically — it ratchets: every
# masked test is listed with a justification, and a NEW one fails the build until it is
# either removed or argued for in the allowlist.
set -euo pipefail
cd "$(dirname "$0")/.."

ALLOW=scripts/allocator-allowlist.txt
# Matches both `ArenaAllocator.init(std.testing.allocator)` and the equally common
# `const testing = std.testing;` ... `ArenaAllocator.init(testing.allocator)` spelling
# (the `std.` prefix is optional). Keep the checker and any allowlist regeneration
# in sync on this pattern — a narrower one silently ungoverns the missed spelling.
PATTERN='ArenaAllocator\.init\((std\.)?testing\.allocator\)'
fail=0

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Validate the allowlist's shape up front: a non-numeric or whitespace-mangled count
# would otherwise make the `-gt`/`-lt` integer comparisons below error out and
# evaluate false, silently unratcheting that file.
while IFS=$'\t' read -r file count _rest; do
  case "$file" in \#*|"") continue ;; esac
  if ! is_uint "$count"; then
    echo "ERROR: $ALLOW has a malformed count '$count' for $file (must be a non-negative integer)."
    fail=1
  fi
done < "$ALLOW"
if [ "$fail" -ne 0 ]; then
  echo "allocator contracts: malformed $ALLOW, fix the count field(s) above"
  exit 1
fi

while IFS= read -r line; do
  file="${line%%:*}"
  count="${line##*:}"
  allowed="$(awk -F'\t' -v f="$file" '$1 == f { print $2 }' "$ALLOW" | head -1)"
  if [ -z "$allowed" ]; then
    echo "ERROR: $file has $count arena-masked test(s) but no allowlist entry."
    echo "       Convert them to raw std.testing.allocator, or add a justified entry to $ALLOW."
    fail=1
  elif [ "$count" -gt "$allowed" ]; then
    echo "ERROR: $file has $count arena-masked test(s), allowlist permits $allowed."
    echo "       A new masked test disables leak detection — convert it or raise the entry with a reason."
    fail=1
  fi
done < <(grep -rcE "$PATTERN" src/ bench/ | grep -v ':0$')

# Stale entries: a file that no longer has masked tests (or no longer exists) should
# drop off the list.
while IFS=$'\t' read -r file count _rest; do
  case "$file" in \#*|"") continue ;; esac
  if [ ! -f "$file" ]; then
    echo "STALE: $file no longer exists but $ALLOW still has an entry — remove it."
    fail=1
    continue
  fi
  # `grep -c` already prints 0 and exits 1 on no match; a bare `|| echo 0` would
  # append a second "0" line to the substitution instead of just falling through,
  # so use `|| true` to keep grep's own "0" output as the only line.
  actual="$(grep -cE "$PATTERN" "$file" || true)"
  if [ "$actual" -lt "$count" ]; then
    if [ "$actual" -eq 0 ]; then
      echo "STALE: $file now has 0 masked test(s), allowlist still claims $count — remove the entry."
    else
      echo "STALE: $file now has $actual masked test(s), allowlist still claims $count — lower it."
    fi
    fail=1
  fi
done < "$ALLOW"

if [ "$fail" -eq 0 ]; then echo "allocator contracts: OK"; fi
exit "$fail"
