### Features

- `zigbase version --json` and `zigbase migrate status --json` emit exactly one JSON object on stdout (prose and warnings go to stderr), for scripts and agents that would otherwise parse the human report.

### Changed

- `zigbase migrate status` now exits **1** when any migration is pending or orphaned, and 0 otherwise, so it can gate a deploy: `zigbase migrate status || zigbase migrate`. It previously always exited 0. The JSON form carries the same signal as `ok`.
- Every CLI usage error (an unrecognized command, an unknown flag, a bad flag value) now exits **1**, program-wide. It previously exited 0 after printing the error and usage — silently telling a script or deploy step that a rejected invocation had succeeded.
