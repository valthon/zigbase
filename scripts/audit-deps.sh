#!/usr/bin/env bash
#
# audit-deps.sh — compare ZigBase's pinned vendored/native dependency versions against the
# curated advisory list in docs/security-advisories.md (#282). Wired to `zig build audit`.
#
# What it does:
#   1. Resolves the PINNED version of each dependency:
#        - sqlite      → the `#define SQLITE_VERSION "..."` in vendor/sqlite/sqlite3.h
#        - sqlite-vec  → the `#define SQLITE_VEC_VERSION "..."` in vendor/sqlite-vec/sqlite-vec.h
#        - zap         → a curated constant, kept in sync with the pin in build.zig.zon
#        - facil.io    → a curated constant (facil.io ships bundled inside the pinned zap)
#        - zigbase     → `.version` in build.zig.zon
#     These are the SAME sources the build aggregates into build_options for the runtime
#     version surfaces, so the audit and the binary can never disagree.
#   2. Parses the "Advisory table" rows out of docs/security-advisories.md. Each row is
#        | Component | Affected range | Min safe version | Advisory | Note |
#      The script only uses `Component` and `Min safe version`; a `Min safe version` of `-`
#      is an informational row and is skipped.
#   3. For every actionable row, flags the dependency as AFFECTED if its pinned version is
#      STRICTLY BELOW the row's `Min safe version` (semver compare via `sort -V`).
#
# Exit status: 0 if all pins are clear; 1 if any pinned version is in a listed affected range;
# 2 on a usage/parse/setup error. Version comparison strips a leading `v`.
#
# Assumptions (kept deliberately simple/robust):
#   - The advisory table is a GitHub-flavored Markdown pipe table; data rows start with `|`.
#   - Component names in the table match the labels above (case-insensitive).
#   - Versions are dotted numeric semver-ish strings comparable with `sort -V`.
set -euo pipefail

# Resolve repo root from this script's location so it works regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ADVISORIES="$ROOT/docs/security-advisories.md"
SQLITE_H="$ROOT/vendor/sqlite/sqlite3.h"
SQLITE_VEC_H="$ROOT/vendor/sqlite-vec/sqlite-vec.h"
ZON="$ROOT/build.zig.zon"

# --- Curated constants (keep in sync with build.zig / build.zig.zon on a re-pin) ---
ZAP_VERSION="0.10.6"
FACIL_VERSION="0.7.4"

die() { echo "audit-deps: $*" >&2; exit 2; }

[ -f "$ADVISORIES" ] || die "advisory list not found: $ADVISORIES"
[ -f "$SQLITE_H" ]    || die "vendored sqlite header not found: $SQLITE_H"
[ -f "$ZON" ]         || die "build.zig.zon not found: $ZON"

# Extract a `#define <MACRO> "value"` string constant from a C header.
read_define() {
  local file="$1" macro="$2" val
  val="$(grep -E "^#define[[:space:]]+${macro}[[:space:]]+\"" "$file" | head -n1 \
         | sed -E "s/^#define[[:space:]]+${macro}[[:space:]]+\"([^\"]*)\".*/\1/")"
  [ -n "$val" ] || die "could not read #define $macro from $file"
  printf '%s' "$val"
}

# Strip a leading 'v' for comparison (sqlite-vec tags are like v0.1.6).
norm() { printf '%s' "${1#v}"; }

# True (0) if $1 < $2 as semver (sort -V). Equal or greater → false (1).
ver_lt() {
  [ "$1" = "$2" ] && return 1
  local smallest
  smallest="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
  [ "$smallest" = "$1" ]
}

SQLITE_VERSION="$(read_define "$SQLITE_H" SQLITE_VERSION)"
if [ -f "$SQLITE_VEC_H" ]; then
  SQLITE_VEC_VERSION="$(read_define "$SQLITE_VEC_H" SQLITE_VEC_VERSION)"
else
  SQLITE_VEC_VERSION="unknown"
fi
ZIGBASE_VERSION="$(grep -E '^\s*\.version\s*=' "$ZON" | head -n1 | sed -E 's/.*"([^"]*)".*/\1/')"
[ -n "$ZIGBASE_VERSION" ] || die "could not read .version from $ZON"

# Map a normalized component label → its pinned version.
pinned_for() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    sqlite)      printf '%s' "$SQLITE_VERSION" ;;
    sqlite-vec)  printf '%s' "$SQLITE_VEC_VERSION" ;;
    zap)         printf '%s' "$ZAP_VERSION" ;;
    facil.io|facil) printf '%s' "$FACIL_VERSION" ;;
    zigbase)     printf '%s' "$ZIGBASE_VERSION" ;;
    *)           printf '' ;;
  esac
}

echo "== ZigBase dependency audit =="
echo "Pinned versions:"
printf '  %-11s %s (source id: %s)\n' "sqlite" "$SQLITE_VERSION" "$(read_define "$SQLITE_H" SQLITE_SOURCE_ID)"
printf '  %-11s %s\n' "sqlite-vec" "$SQLITE_VEC_VERSION"
printf '  %-11s %s\n' "zap" "$ZAP_VERSION"
printf '  %-11s %s\n' "facil.io" "$FACIL_VERSION"
printf '  %-11s %s\n' "zigbase" "$ZIGBASE_VERSION"
echo
echo "Checking against docs/security-advisories.md ..."

affected=0
checked=0

# Parse the markdown pipe table. Data rows start with '|'. Skip the header row
# (Component ...) and the |---|---| separator. Columns are 1=Component, 3=Min safe.
while IFS= read -r line; do
  case "$line" in
    \|*) : ;;        # a table row
    *) continue ;;   # non-table line
  esac
  # Split on '|' into fields, trimming surrounding whitespace.
  IFS='|' read -r _lead c_comp c_range c_minsafe c_rest <<EOF
$line
EOF
  comp="$(printf '%s' "${c_comp:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  minsafe="$(printf '%s' "${c_minsafe:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  # Skip header + separator + blank component cells.
  [ -z "$comp" ] && continue
  [ "$comp" = "Component" ] && continue
  case "$comp" in ---*|:--*|*---) continue ;; esac
  # Informational rows (no fixed version) use '-'.
  [ "$minsafe" = "-" ] || [ -z "$minsafe" ] && continue

  pinned="$(pinned_for "$comp")"
  if [ -z "$pinned" ]; then
    echo "  ? $comp: advisory row references an unknown component (min safe $minsafe) — skipping"
    continue
  fi
  if [ "$pinned" = "unknown" ]; then
    echo "  - $comp: pinned version unknown (dependency not present) — skipping"
    continue
  fi

  checked=$((checked + 1))
  if ver_lt "$(norm "$pinned")" "$(norm "$minsafe")"; then
    echo "  ✗ AFFECTED: $comp $pinned < min safe $minsafe"
    affected=$((affected + 1))
  else
    echo "  ✓ ok: $comp $pinned >= min safe $minsafe"
  fi
done < "$ADVISORIES"

echo
if [ "$affected" -gt 0 ]; then
  echo "RESULT: $affected affected pin(s) found across $checked check(s). Update the vendored dependency"
  echo "        (or re-pin zap) and re-run 'zig build audit'. See docs/security-audit.md."
  exit 1
fi
echo "RESULT: OK — $checked advisory check(s) passed; no pinned version is in a known-affected range."
exit 0
