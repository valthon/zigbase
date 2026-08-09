### Internal

- `changelog.d/README.md` now warns up front that `scripts/assemble-changelog.sh` is destructive —
  it rewrites `CHANGELOG.md` and `git rm`s every fragment in the directory, including ones
  belonging to other open PRs — and that it is a release-time tool, not a way to check that your
  own fragment parses. Its name reads like a validator, which is exactly the trap.
