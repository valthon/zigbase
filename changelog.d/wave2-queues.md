### Features

- Background jobs & queues: a generic multi-queue / worker / job engine. Declare named
  `.queues` (backend `memory` (default) or `durable`, a `high`/`normal`/`low` `priority`, and a
  per-queue retry policy), named `.workers` (each bound to a subset of queues, drained in strict
  priority order, with a `concurrency` knob), and a `.jobs` kind→handler registry. A `.default`
  queue is always synthesized, and with no `.workers` declared a single implicit worker drains all
  queues. Enqueue from anywhere (routes, hooks, jobs) with the compile-checked
  `App.enqueue(ctx, .queue, .kind, payload)` or the runtime-validated `ctx.enqueue(.queue, .kind, payload)`;
  the payload is JSON-serialized and the kind handler receives that JSON.
- Durable queues persist to a new `_queue_jobs` table and are drained by a per-worker poller with
  at-least-once delivery: jobs are claimed under the writer, dispatched, then marked done / retried
  with backoff / failed (firing `.onError`) once attempts are exhausted. A reclaim sweep resets jobs
  stranded by a crashed worker, and a GC sweep reaps old done/failed rows — both installed only when
  a durable queue is declared (memory-only and no-queue apps install nothing).
- Memory queues run in-process on a detached thread with backoff retry (at-most-once across restart),
  so a queue works with zero schema by default.
