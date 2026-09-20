# Engineering backlog

## Direction and decision rule

Build beyond your team size: give individuals and small teams the application leverage
of an integrated framework with explicit resource control, deep extensibility, and
an efficient deployment model. Frontier coding agents are a core development workflow;
writing the application directly must remain equally supported.

Prioritize changes that increase useful application capability per developer-hour or
per unit of hardware. Reliability preserves those gains through changes, overload, and
recovery. New features should earn their runtime cost and maintenance burden.

Checked items describe implemented work in the repository; consult release notes for
availability. Unchecked items are planned or partial, not delivery commitments. Keep
capabilities independently reviewable, explicitly resource-bounded, and compiled out
where disabled. Ship canonical docs, relevant site copy, examples, and tests with each
implementation. [Why ZigBase](docs/why-zigbase.md) connects this work to the product pitch.

## Priority sequence and completion evidence

### P1 — Prove useful application performance on modest hardware

- [ ] **Representative application capacity report.** Build on the existing examples,
  benchmark harness, resource profiles, tuning advisor, and performance contracts.
  Exercise authenticated, tenant-scoped reads/writes, relation expansion, realtime,
  and background work together. Publish the app/revision, dataset and indexes, machine,
  build flags, load generator, warmup, duration, errors, throughput, p50/p95/p99 latency,
  process RSS, CPU, and disk use. Report saturation and recovery, not only a peak RPS.
  Include a reproducible small-machine baseline before broader enterprise-scale claims.
  Implemented: a [bounded mixed project/task runner](docs/testing.md#application-capacity)
  exercises authenticated native-tenant lists, writes, relation expansion, live SSE
  delivery, and transactional durable digest jobs. Normal-load, stress, and recovery
  phases retain semantic/isolation checks, client latency distributions, job drain,
  process RSS/CPU, and binary/resource provenance. CI runs correctness checks without
  timing gates. Offered load alone is not evidence of saturation; a controlled
  small-machine saturation/recovery report and external-service jobs remain open.
- [ ] **Coordinated resource envelope.** Extend existing HTTP/memory-job admission and
  retained-payload byte limits to the uncovered resource paths below. Demonstrate bounded queues and
  predictable degradation under mixed overload; report which subsystem saturated and
  measure process memory in addition to instrumented allocations. Configuration must
  distinguish hard limits, advisory budgets, and costs outside framework accounting.
- [ ] **One performance-engineering walkthrough.** Start from the capacity fixture,
  identify an actual bottleneck, change a resource or query choice, and compare the
  result with `resources`, `tune`, and performance contracts. Preserve raw observations
  and label measured results separately from recommendations. Complete when a developer
  can reproduce the decision without AI and an agent can follow the same procedure.
  First worked example: [durable batch sizing](diagnostics/application-capacity/batch-sizing/README.md)
  preserves paired mixed-workload reports and explains observed polling/drain latency.
  Dedicated-machine performance qualification and advisor/contract integration remain open.

### P1 — Make custom applications productive in both workflows

- [ ] **Application-evolution evaluation.** Extend the historical Genesis creation
  scenario with populated-data schema changes, team membership/ownership changes,
  a custom transaction, and a dependency upgrade. Independently verify old and new
  journeys, authorization, migrations, and restart/restore behavior. Record agent/model,
  pinned revisions, elapsed time, interventions, and available token/cost data. Do not
  qualify a later release with an earlier checkpoint.
- [ ] **Framework extension feedback.** Use the same app tasks for a documented manual
  walkthrough and an unattended agent run. Track compiler/debugging friction, especially
  result lifetimes, transaction boundaries, custom routes, and plugin contracts. Improve
  public APIs or diagnostics where failures recur; retain explicit resource control.
  Completion requires runnable examples and useful errors, not an AI-only workaround.
- [ ] **Reproducible test feedback.** Preserve command status and test summaries in
  unattended runs; extend the existing structured diagnostics and focused execution to cover
  more application workflows. Keep CLI commands useful from an ordinary terminal and CI.

### P2 — Demonstrate the growth path and reduce operating effort

- [ ] **SQLite-to-PostgreSQL growth rehearsal.** Use the capacity app and populated data
  to document when the move helps, cutover/rollback, backend-specific SQL changes,
  shared storage, job ownership, and cross-instance realtime. Measure at least one
  single-instance and one multi-instance deployment. Publish database costs and bottlenecks
  separately; adding replicas must not be presented as an unlimited scale guarantee.
- [ ] **Capacity attribution.** Extend the bounded query workbench below with actionable
  route/job and optional tenant-level accounting. Define cardinality/retention limits,
  sampling overhead, and sensitive-data exclusions. A solo operator should be able to
  identify a costly operation and verify a fix without assembling another telemetry stack.
- [ ] **Operating rehearsals.** Automate backup/restore verification, interrupted work,
  external-service failure, and upgrade/rollback checks for the capacity app. Record
  operator actions and recovery time; retain explicit at-least-once and idempotency
  semantics. Build on existing deployment and migration tools rather than duplicating them.

### Positioning and evidence maintenance

- [x] Lead the homepage, README, and docs with small-team ambition, framework extensibility,
  and resource control; expose direct development and coding-agent paths together.
- [x] Publish a why-Zig guide and this backlog with clear links between existing tools,
  known boundaries, and future objectives. Mark the older ideas document as historical.
- [ ] Refresh application and agent evidence for release candidates; record exact revisions
  and configuration. Comparative performance/cost claims need equivalent workloads,
  documented methodology, and reproducible results before they enter marketing copy.
- [ ] Keep ZigBase and Zigapagos positioning aligned around the complete application.
  Validate a paired app's frontend build, interaction, backend, and deployment costs;
  keep independent frontend/framework choices documented.

The items below retain the implementation backlog. The sequence above provides the
product priority and acceptance evidence; it does not create duplicate implementations.

## Development and resource efficiency

- [x] Transparent comptime resource profiles with explicit overrides and an effective-settings report (#410).
- [x] Offline workload tuning advisor comparing supplied throughput, tail latency, and memory measurements under explicit budgets (#413).
- [ ] Coordinated resource budgets, bounded queues, backpressure, and saturation diagnostics.
  Implemented slice: opt-in synchronous HTTP admission, immediate overload rejection,
  and saturation counters; the shared WS/SSE connection cap is comptime-tunable
  with effective cap/count reporting. Build-gated `.admission.max_work` now shares
  a process-local count across synchronous HTTP and outstanding memory-job/submit
  work, including queued tasks and retries, with immediate rejection and counters.
  Optional `.admission.max_job_bytes` now bounds precisely retained memory-job
  payload/submit-name copies, with atomic reservation and byte diagnostics.
  Optional durable queue capacity now rejects retained row/payload overflow atomically
  across configured SQLite/PostgreSQL producers, with bounded database snapshots.
  All retained statuses count until GC/deletion, and shared execution admission
  reserves one permit per serial durable poll batch before claiming. Transport
  buffers, durable claim allocations, broader byte/RSS budgets and remaining
  cross-subsystem coordination are still outside these gates.
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
  Local performance-contract, parity-replay and agent-tool regression modules are
  also inventoried, with explicit tool/contract dependency mappings.
  TypeScript SDK unit execution now has an explicit suite selector with pinned
  Node, bounded worker count and structured evidence; SDK path changes select it.
  Python SDK unit execution has a matching pinned, serial selector with explicit
  async-test support and checkout-source isolation; live integration remains separate.
  This is not a remote executor or arbitrary embedded-app test discovery. Broader
  test-runner coverage and inferred dependency graphs remain.
  Offline migration preview now reports compiled consumer callback/transaction declarations
  without configuration or database access. Pending state, SQL/effects and runtime
  reversibility remain unknown; executable migration planning is not implemented.
- [ ] Opt-in bounded query performance workbench with route attribution and query-plan inspection.
  Implemented first slice: build-gated SQLite synchronous prepared-statement step
  metrics by route template/opaque structural shape; bounded slow/repeated counters
  and bearer-superuser-only generated SELECT-plan inspection. Completed-statement
  lifecycle timing separates measured calls from held intervals. A separate bounded
  method/template table now reports completed synchronous dispatch counts, total/max
  duration and slow scopes, including SQL-free/error/denied handlers. It does not
  classify status or measure transport, detached jobs, or exclusive pool-wait time.
  PostgreSQL now
  measures bounded client-side prepared exchanges with backend-aware attribution;
  PostgreSQL plans, full request/pool-wait latency, captured plans and automatic
  index advice remain deferred.
- [ ] **Deferred:** dependency-aware bounded response caching. PR #425 was evaluated
  and did not justify further investment. Revisit only if representative application
  measurements establish a concrete need; no additional cache work is planned now.
- [x] Opt-in application performance contracts: binary-size/allocation gates and advisory timing comparisons (#414).
- [ ] Opt-in principal/operation-scoped idempotent mutations with atomic coordination and bounded retention.
  Implemented slice: lazy comptime-configured SQLite/PostgreSQL custom-operation receipts,
  mandatory current authorization, atomic DB effects/results, bounded per-namespace
  capacity and expiry cleanup. Opt-in authenticated JSON REST create/update/delete now
  reuse transactional receipts with explicit collection eligibility, current replay
  authorization, schema/body binding and bounded refusal. PostgreSQL coordinates namespaces across replicas
  with fail-fast transaction locks. Hook/file/auth collection workflows and external
  side-effect orchestration remain outside the REST adapter.
- [ ] Complete upstream test-runner diagnostic follow-up (#261; investigation PR #355).
  The reproduced Zig 0.16.0 symptom is a stale failed-command label after successful
  exit-time stderr, not a demonstrated race. Supported `zigbase.addTest` avoids it.
  A dependency-free 14-case stock/simple-runner regression verifies success, meaningful
  stderr, skips, assertions, leaks, logged errors, and post-test signals in CI.
  Upstream compiler correction/submission remains open; nonzero exits still require
  independent diagnosis.

## Schema hardening


- [x] Reconcile index-only comptime schema changes transactionally without table rebuilds.
- [x] Preserve unrelated migration-owned indexes and adopt matching ordinary indexes.
- [x] Log authoritative index changes and diagnose startup failures by collection/index.
- [x] Validate prospective access-rule field/relation references in schema apply and REST.
- [x] Cover retained cross-collection rules and explain whole-snapshot validation.
- [x] Explicit offline collection rename: database/auth/search references and immutable storage namespaces across file consumers, durable uploads/cleanup, thumbnails, and reconciliation. Old URLs/topics intentionally break pre-v1; reserved physical prefixes are never automatically reclaimed.

## System migrations (#398)

- [x] Serialize system migrations and public ledger bootstrap across PostgreSQL replicas.
- [x] Preserve caller transactions on refusal and release locks on failure.
- [x] Coordinate PostgreSQL consumer apply/rollback batches, including non-transactional callbacks.
- [x] Coordinate current-version SQLite consumer apply/rollback batches with a bounded, fail-fast sidecar lock.
- [ ] Older binaries, automatic provisioning and external migration writers still require a single leader.
- SQLite consumer batches deliberately fail fast with `MigrationBusy`; unlike PostgreSQL advisory-lock waits, supervisors must retry after the active batch finishes. Revisit bounded startup waiting only if deployments need it.

## Realtime fanout (#403)

- [x] Measure actual delivery authorization, allocations, and subscriber fanout.
- [x] Exercise benchmark correctness under ReleaseSafe in CI.
- [x] Bounded single-process SQLite backfill with current authorization and explicit gap semantics (#412).
- [ ] Durable cross-instance replay with explicit resource and retention budgets.
  Implemented: opt-in transactional SQLite/PostgreSQL built-in REST invalidations,
  shared 4096-entry / 4 MiB / 24-hour retention, commit-ordered checkpoints,
  restart/cross-instance recovery, and current per-item authorization. Data/raw-SQL,
  hook side-writes and custom-channel capture remain outside this REST scope;
  end-to-end replay coverage and configurable per-workload retention remain open.

## Analytics batching (#401)

- [x] Capture explicit atomic batches with server-stamped identity and bounded inputs.
- [x] Preserve outer transaction ownership and provide a nameable runtime input type.

## Files and storage

- [x] Opt-in read-only storage inventory for local and S3 backends (#400).
- [x] S3 multipart upload with bounded request scratch, retries, best-effort abort,
  completion-error handling, and live S3-compatible integration coverage.
- [ ] Resumable client uploads with principal-bound capabilities and commit reauthorization.
  Implemented slice: opt-in bounded, process-local sessions for one file on an existing
  record, with fresh authentication and commit reauthorization. Additional opt-in
  SQLite/local persistence survives process restarts under one owner, preserving
  atomic completion receipts and never replaying uncertain hooks. Cross-instance,
  power-loss durability and streaming remain future work.
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
