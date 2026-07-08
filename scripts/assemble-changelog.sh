#!/usr/bin/env bash
# Assemble changelog fragments from changelog.d/ into a new release section.
#
# Each PR drops a fragment file changelog.d/<slug>.md (see changelog.d/README.md) instead
# of editing CHANGELOG.md, so parallel PRs never conflict on the shared file. A fragment
# contains one or more `### <Section>` headings (each with bullet lines); a single fragment
# may populate multiple sections. At release this script aggregates the bullets per section
# across ALL fragments, emits each non-empty section (in canonical order) under one new
# `## [<version>] - <date>` block, inserts it into CHANGELOG.md (above the first released
# version, below `## [Unreleased]`), and deletes the consumed fragments. The published
# site mirror is regenerated from CHANGELOG.md at build time by
# site/scripts/gen-docs-mirror.mjs — this script no longer touches it directly.
#
# Usage: scripts/assemble-changelog.sh [<version> [<date>]] [--dry-run]
#   <version>  defaults to build.zig.zon's .version (the single source of truth).
#   <date>     defaults to today (UTC), YYYY-MM-DD.
#   --dry-run  print the assembled section + which fragments would be removed; touch nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    *) ARGS+=("$a") ;;
  esac
done

VERSION="${ARGS[0]:-$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | cut -d'"' -f2)}"
DATE="${ARGS[1]:-$(date -u +%Y-%m-%d)}"
FRAG_DIR="changelog.d"
CANONICAL="CHANGELOG.md"

# Canonical sections, in the order they are emitted. Empty ones are omitted at assembly.
# The consumer-facing sections come first; Internal (contributor-facing) renders last.
SECTIONS=(Breaking Features Fixes Changed Performance Deprecated Removed Security Internal)
is_section() {
  for s in "${SECTIONS[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

# Collect fragments. A fragment is changelog.d/<slug>.md (README.md is not a fragment).
shopt -s nullglob
FRAGMENTS=()
for f in "$FRAG_DIR"/*.md; do
  [ "${f##*/}" = "README.md" ] && continue
  FRAGMENTS+=("$f")
done
shopt -u nullglob

if [ "${#FRAGMENTS[@]}" -eq 0 ]; then
  echo "::error::no fragments in $FRAG_DIR/ — nothing to assemble for $VERSION." >&2
  echo "Add changelog.d/<slug>.md fragments before releasing (see $FRAG_DIR/README.md)." >&2
  exit 1
fi

# Aggregate bullets per section across all fragments into temp files, one per section
# ($WORK/section_<Name>). A fragment is a sequence of `### <Section>` headings, each
# followed by its bullet/body lines. Content before any heading, or an unknown section
# name, fails loudly.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in "${FRAGMENTS[@]}"; do
  current=""
  saw_section=0
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      "### "*)
        name="${line#"### "}"
        name="${name%"${name##*[![:space:]]}"}"   # rstrip trailing whitespace
        if ! is_section "$name"; then
          echo "::error::fragment '$f' line $lineno: unknown section '### $name'." >&2
          echo "Recognized sections: ${SECTIONS[*]}" >&2
          exit 1
        fi
        current="$name"
        saw_section=1
        ;;
        # Blank lines are dropped: changelog sections are tight bullet lists, and dropping
        # them lets bullets aggregate across fragments without spurious interior gaps.
      "") ;;
      *)
        if [ -z "$current" ]; then
          echo "::error::fragment '$f' line $lineno: content before any '### <Section>' heading:" >&2
          echo "  $line" >&2
          exit 1
        fi
        printf '%s\n' "$line" >> "$WORK/section_$current"
        ;;
    esac
  done < "$f"
  if [ "$saw_section" -eq 0 ]; then
    echo "::error::fragment '$f' has no '### <Section>' heading (see $FRAG_DIR/README.md)." >&2
    exit 1
  fi
done

# Build the assembled block: the version heading, then each non-empty section in canonical
# order. Section buckets hold only non-blank lines (blanks were dropped during parsing), so
# bullets aggregate tightly with one blank line between heading and list.
SECTION="$WORK/__section__"
{
  echo "## [${VERSION}] - ${DATE}"
  for s in "${SECTIONS[@]}"; do
    file="$WORK/section_$s"
    [ -s "$file" ] || continue
    echo
    echo "### $s"
    echo
    cat "$file"
  done
} > "$SECTION"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== assembled section for ${VERSION} (${DATE}) ==="
  cat "$SECTION"
  echo "=== would remove ${#FRAGMENTS[@]} fragment(s) ==="
  printf '  %s\n' "${FRAGMENTS[@]}"
  exit 0
fi

# Insert the section into a target changelog, immediately before the first released
# version heading (`## [x.y.z]`), i.e. just below the `## [Unreleased]` block. awk keeps
# the file's frontmatter/intro/Unreleased placeholder and all prior versions intact.
insert_into() {
  target="$1"
  [ -f "$target" ] || { echo "::error::changelog not found: $target" >&2; exit 1; }
  # Created under $WORK so the EXIT trap (rm -rf "$WORK") reaps it even on interrupt.
  tmp="$(mktemp "$WORK/insert.XXXXXX")"
  awk -v sectionfile="$SECTION" '
    BEGIN { inserted = 0 }
    # First released-version heading: "## [1.2.3]" (digit after the bracket), not "[Unreleased]".
    !inserted && /^## \[[0-9]/ {
      while ((getline l < sectionfile) > 0) print l
      print ""
      inserted = 1
    }
    { print }
    END { if (!inserted) { print "::error::no released-version heading found to anchor insert" > "/dev/stderr"; exit 3 } }
  ' "$target" > "$tmp"
  mv "$tmp" "$target"
  echo "inserted ${VERSION} section into $target"
}

insert_into "$CANONICAL"

# Remove the consumed fragments (git rm when tracked, plain rm otherwise so the script
# works on an untracked sample copy too).
for f in "${FRAGMENTS[@]}"; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    git rm -q "$f"
  else
    rm -f "$f"
  fi
done
echo "removed ${#FRAGMENTS[@]} consumed fragment(s) from $FRAG_DIR/"
