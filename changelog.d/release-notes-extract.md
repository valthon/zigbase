### Internal

- Release process: GitHub release descriptions now contain only the released version's changelog section (via the new `scripts/extract-release-notes.sh`), not the entire `CHANGELOG.md`. Both `release.yml` and `scripts/release.sh` use per-version notes.
