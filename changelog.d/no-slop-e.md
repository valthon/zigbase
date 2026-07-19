### Security

- Per-route rate limiting no longer collapses every client into a single shared bucket when the client cannot be identified (a `.custom` route limit with no `rate_limit_key`, on a directly-exposed server where `ZIGBASE_TRUST_PROXY` is off and the client IP is unknown). Previously one anonymous caller could exhaust the shared bucket and 429 the route for everyone. The bucket is now keyed per client — the app-supplied key function, else the trusted-proxy client IP, else the authenticated principal — and when none of those can distinguish the caller the limit is skipped (fail-open) with a one-time warning rather than enforced as a poisonable global bucket.

### Fixes

- Additive `ADD COLUMN` steps in the system migrations (session `token_epoch`, `_collections.options`, `_suppressions.updated`) no longer swallow every error as if it were the benign "duplicate column" case. A genuine DDL failure (lock timeout, disk full, connection drop) now propagates and aborts the migration instead of being recorded as applied with the column still missing — which could permanently break token issue/verify for an auth collection with no migration-based repair. Idempotence now comes from a backend-catalog column-existence check.
- On Postgres builds, a numbered placeholder `?N` in developer-authored raw SQL with an out-of-range or overflowing index (for example `?10000000` or a 20-plus-digit run) now surfaces a prepare error instead of panicking the process at statement-execution time.
- Outbound webhook delivery now bounds the total time one attempt sequence spends sleeping between retries, so a receiver returning a large `Retry-After` (or a long configured backoff) can no longer keep a delivery running past the queue's `visibility_timeout_s` — which previously let the job be re-dispatched as a concurrent duplicate and stalled other jobs on the worker for minutes.
- Fixed a table-name string leak on the out-of-memory error path of the database dump-load (`migrate load`) copy loop.

### Internal

- System migration 0010 allocates its collection-name scratch list from the run-scoped migrator arena instead of `std.heap.page_allocator`, restoring `std.testing.allocator` leak visibility for that path and removing ~15 lines of manual cleanup.
