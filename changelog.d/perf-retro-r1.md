### Fixes

- Shipped-binary size: fixed a code-gen accident in the bundled regex engine (`Builder`
  was materialized as a ~3 MB all-zero `.rodata` template copied at runtime on every
  `compile`) — the default ReleaseSafe binary shrinks ~40%, from ~7.6 MB to ~4.6 MB,
  with identical behavior.
- `app.submit` tasks and memory-queue jobs are now drained and joined at shutdown (a task
  submitted before shutdown completes instead of being cut off), and `app.submit` works
  whenever the server is running — a configured scheduler is no longer required.

### Performance

- Memory-backend queues no longer spawn one detached OS thread (with a 1 MiB stack) per
  enqueued job: jobs run on a small fixed worker pool with a bounded ring. Overflow
  returns `error.QueueFull` instead of unbounded thread creation, so enqueue bursts can
  no longer exhaust threads or address space.
- Realtime delete fan-out: the per-subscriber authorization sandbox for delete events now
  creates only the tables it needs (2 statements) instead of running the full ~28-table
  migration suite once per subscriber per delete — removing the worst per-event fan-out
  cost on the shared HTTP threads.
- Collection metadata (the parsed schema consulted by every record API request and every
  realtime delivery) is now served from a versioned in-process cache invalidated on
  collection create/update/delete (SQLite backend; Postgres deployments keep direct reads
  so multi-instance DDL stays coherent) — removing a `_collections` SELECT plus a full
  schema-JSON parse per request and per realtime fan-out delivery.
- The embedded admin UI's assets now carry build-time `ETag`s and answer `If-None-Match`
  with `304 Not Modified`, so revisiting the admin no longer re-downloads the SPA bundle
  on every load.

### Internal

- Corrected a false load-bearing comment in `static_files.zig` (facil.io does NOT
  percent-decode request paths; the `..` check is safe because encoded traversal stays a
  literal segment) and documented why `query/params.zig` keeps its own query parser
  (fio type-guesses values; zap returns them undecoded).
