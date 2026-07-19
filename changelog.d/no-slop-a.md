### Fixes
- Creating or updating a record with file uploads no longer orphans the uploaded bytes in storage when the write is rolled back (a failed commit, a denied access-rule guard, or a validation error) — the just-written files are now always removed on any pre-commit failure.
- Failures while cleaning up files after a delete/update (e.g. a transient object-store error) are now logged instead of silently swallowed, so orphaned-file accumulation is diagnosable.
- A malformed or out-of-range numeric value in a `filter`, `sort`, or cursor (e.g. `price=99999999999999999999`) now returns `400 Invalid filter or sort.` instead of `500`.
- The request error path no longer risks panicking the server (or invoking undefined behavior in a `ReleaseFast` embed) when the machine is out of memory: rendering a 500 that itself fails to allocate now falls back to a preallocated static error body.

### Internal
- Record create/update file-cleanup is consolidated behind a single commit-guarded scope guard instead of the same delete block copy-pasted into four return branches.
- `records.last_errors` (validation-detail threadlocal) is cleared once consumed, so it never outlives the per-request arena it points into.
- `gcExpiredRecords` (TTL sweep) now allocates its per-collection scratch from an internal arena, making it leak-free for any caller allocator rather than only arena callers.
