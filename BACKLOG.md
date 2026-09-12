# Engineering backlog

Checked items describe implemented work; consult release notes for availability.
Keep each new capability independently reviewable, explicitly resource-bounded,
and compiled out where disabled. Include canonical docs, relevant public-site
copy, examples, and tests with the implementation rather than in follow-up PRs.

## Development and resource efficiency

- [x] Transparent comptime resource profiles with explicit overrides and an effective-settings report (#410).
- [x] Offline workload tuning advisor comparing supplied throughput, tail latency, and memory measurements under explicit budgets (#413).
- [ ] Coordinated resource budgets, bounded queues, backpressure, and saturation diagnostics.
  Implemented slice: opt-in synchronous HTTP admission, immediate overload rejection,
  and saturation counters; the shared WS/SSE connection cap is comptime-tunable
  with effective cap/count reporting. Transport buffers and cross-subsystem budget
  coordination remain outside these gates.
  Memory-job/submit workers now have independent comptime counts and share the
  configured job stack size, with lazy startup and unchanged bounded-ring rejection.
- [ ] Agent-native development interface: versioned discovery, structured diagnostics,
  schema/route inspection, migration previews, and focused test execution.
  Implemented slices: CLI discovery with explicit operation side effects (#409),
  offline compiled-route inspection with declarative access metadata (#415), and
  structured diagnostics with typed required-input descriptors (#416), and
  bounded repository-only pytest inventory/selection with structured process results.
  Selection-only changed-file inspection now maps curated dependencies to bounded
  module checks, with whole-allowlist fallback and explicit coverage gaps.
  This is not a remote executor or arbitrary embedded-app test discovery. Broader
  test-runner coverage and inferred dependency graphs remain.
  Offline migration preview now reports compiled consumer callback/transaction declarations
  without configuration or database access. Pending state, SQL/effects and runtime
  reversibility remain unknown; executable migration planning is not implemented.
- [ ] Opt-in bounded query performance workbench with route attribution and query-plan inspection.
  Implemented first slice: build-gated SQLite synchronous prepared-statement step
  metrics by route template/opaque structural shape; bounded slow/repeated counters
  and bearer-superuser-only generated SELECT-plan inspection. PostgreSQL, full
  query/request latency, captured plans and automatic index advice remain deferred.
- [ ] Dependency-aware bounded response caching, starting with explicitly eligible public reads.
- [x] Opt-in application performance contracts: binary-size/allocation gates and advisory timing comparisons (#414).
- [ ] Opt-in principal/operation-scoped idempotent mutations with atomic coordination and bounded retention.
  Implemented slice: lazy comptime-configured SQLite custom-operation receipts,
  mandatory current authorization, atomic DB effects/results, bounded per-namespace
  capacity and expiry cleanup. Built-in REST mutations, PostgreSQL and external
  side-effect orchestration remain outside this helper.
- [ ] Resolve intermittent test-runner diagnostics (#261); existing investigation is PR #355.

## Schema hardening


- [x] Reconcile index-only comptime schema changes transactionally without table rebuilds.
- [x] Preserve unrelated migration-owned indexes and adopt matching ordinary indexes.
- [x] Log authoritative index changes and diagnose startup failures by collection/index.
- [x] Validate prospective access-rule field/relation references in schema apply and REST.
- [x] Cover retained cross-collection rules and explain whole-snapshot validation.
- [ ] Explicit collection rename spanning tables, relations, FTS, storage keys, and URLs.

## System migrations (#398)

- [x] Serialize system migrations and public ledger bootstrap across PostgreSQL replicas.
- [x] Preserve caller transactions on refusal and release locks on failure.
- [x] Coordinate PostgreSQL consumer apply/rollback batches, including non-transactional callbacks.
- [ ] Older binaries and multi-process SQLite migration workflows still require a single leader.

## Realtime fanout (#403)

- [x] Measure actual delivery authorization, allocations, and subscriber fanout.
- [x] Exercise benchmark correctness under ReleaseSafe in CI.
- [x] Bounded single-process SQLite backfill with current authorization and explicit gap semantics (#412).
- [ ] Durable cross-instance replay with explicit resource and retention budgets.

## Analytics batching (#401)

- [x] Capture explicit atomic batches with server-stamped identity and bounded inputs.
- [x] Preserve outer transaction ownership and provide a nameable runtime input type.

## Files and storage

- [x] Opt-in read-only storage inventory for local and S3 backends (#400).
- [x] S3 multipart upload with bounded request scratch, retries, best-effort abort,
  completion-error handling, and live S3-compatible integration coverage.
- [ ] Resumable client uploads with principal-bound capabilities and commit reauthorization.
  Implemented slice: opt-in bounded, process-local sessions for one file on an existing
  record, with fresh authentication and commit reauthorization. Durable restart-safe
  and cross-instance resume remain future work.
- [ ] Image transforms/thumbnails with comptime support and resource budgets.
  Implemented slice: default-off ImageMagick transforms for local PNG/JPEG/WebP
  files, named comptime contain/cover/output profiles and tunable process/admission
  budgets. Remote backends, persistent derivative storage and arbitrary
  transformation pipelines remain future work.
- [x] Opt-in durable HTTP replacement/deletion cleanup with physical reference checks (#411).
- [ ] Scoped orphan reconciliation and cleanup for non-HTTP mutation paths.
  Implemented slice: bounded offline local/SQLite reconciliation with read-only
  dry-run, explicit deletion, boot-lifetime storage leases and fresh physical
  reference checks. Older/external writers must be stopped. Online/distributed
  cleanup, S3/PostgreSQL/custom storage and dropped-collection prefixes remain.
