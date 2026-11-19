#!/usr/bin/env bash
# Configure (`zig build -l`) in the two source layouts PR CI never exercises:
#   1. a plain clone on a branch: HEAD is a symbolic ref and .git/commondir is absent
#      (what CI sees on a push to main, nightly fuzz, and most developer clones);
#   2. a tree with no .git at all (a fetched package, a source tarball).
# PR runs check out a detached merge commit, so build.zig's Git provenance code
# returns before it reads commondir or refs; a configure input registered for a
# missing file then fails only after merge, as `configuration failed: FileSystemFailure`.
#
# Usage: scripts/check-configure-checkouts.sh   (run after scripts/zig-fetch.sh;
# uses $ZIG_GLOBAL_CACHE_DIR for packages and a throwaway local cache per tree)
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone --quiet --no-hardlinks "$root" "$work/branch"
git -C "$work/branch" checkout --quiet -B configure-probe
mkdir "$work/nogit"
git -C "$root" archive HEAD | tar -x -C "$work/nogit"

# Resolve zig here: the temporary trees carry an untrusted copy of mise.toml.
zig="$(mise exec zig@0.17.1 -- sh -c 'command -v zig')"

status=0
for tree in branch nogit; do
  if (cd "$work/$tree" && "$zig" build -l --cache-dir "$work/$tree-cache" >/dev/null); then
    echo "configure OK: $tree"
  else
    echo "::error::zig build configuration failed in the '$tree' layout (see above)" >&2
    status=1
  fi
done
exit "$status"
