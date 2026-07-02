> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/jobs-and-webhooks> — the site is the canonical reading experience.

# Jobs & webhooks

`.cron`/`app.submit` are for *scheduled* and *fire-and-forget* work. For **enqueued background
jobs** with retries, priorities, and optional durability, ZigBase ships a generic multi-queue /
worker / job engine — the same engine backs the built-in `mail` and `webhook` job kinds. This
guide covers configuring queues/workers/jobs, enqueueing work, the durability/retry model, and
`ctx.webhook()`'s managed outbound-webhook delivery.

## Queues, workers, jobs

Three config keys lower at comptime:

```zig
App(.{
    // Named queues. `.default` (memory/normal) is ALWAYS synthesized if you don't declare it.
    .queues = .{
        .emails = .{
            .backend  = .durable,   // .memory (default) | .durable
            .priority = .high,      // .high | .normal (default) | .low
            .retry    = .{ .max_attempts = 5, .backoff = .exponential, .base_ms = 1000, .max_ms = 300_000, .jitter = true },
        },
        .reports = .{ .backend = .durable, .priority = .low },
    },
    // Named workers, each draining a subset of queues in STRICT priority order.
    // OMIT `.workers` entirely → ONE implicit worker drains ALL queues, strict priority.
    .workers = .{
        .mailer  = .{ .queues = .{"emails"}, .concurrency = 4 },
        .general = .{ .queues = .{ "reports", "default" } },
    },
    // Job-kind registry: kind name → handler `fn(*Ctx, payload: []const u8) anyerror!void`.
    .jobs = .{
        .resize_image = resizeImage,
        .reindex      = reindex,
    },
})
```

If you declare no `.queues` and no `.workers` at all, the always-present `default` queue (memory,
normal priority) and its one implicit worker are still there — you can `enqueue` into it with
zero configuration.

## Enqueue work

A job handler receives the JSON payload as bytes and deserializes it:

```zig
fn resizeImage(ctx: *zigbase.Ctx, payload: []const u8) anyerror!void {
    const parsed = try std.json.parseFromSlice(struct { id: []const u8 }, ctx.arena, payload, .{});
    // …do the work; touch the DB via ctx.records() / ctx.app.pool.acquireWriter()…
}
```

From any route, hook, or job:

```zig
// Compile-checked (a typo'd queue or kind is a COMPILE ERROR), mirrors App.flag:
try App.enqueue(ctx, .emails, .resize_image, .{ .id = "abc123" });

// Runtime-validated escape hatch (errors UnknownQueue / UnknownJobKind):
try ctx.enqueue(.emails, .resize_image, .{ .id = "abc123" });
```

`payload` is JSON-serialized (a `[]const u8` is treated as raw JSON and passed through unchanged),
and the job is routed to the named queue's backend.

## Durability & retries

- **Backend `memory`** (default): the job runs in-process on a detached thread with backoff
  retry. **At-most-once across restart** — an enqueued memory job lives only in RAM, so a
  crash/shutdown before it completes drops it. Zero schema; great for best-effort work.
- **Backend `durable`**: the job is persisted to the `_queue_jobs` table and drained by a
  per-worker poller. **At-least-once** — a crash after a side effect but before the row is marked
  done replays the job, so durable consumers must tolerate replays (idempotency keys are the
  antidote). A **reclaim sweep** resets jobs stranded by a crashed worker (claimed longer than
  that queue's `visibility_timeout_s`), and a GC sweep reaps done/failed rows older than its
  `done_ttl_s` — **both are per-queue** (set `visibility_timeout_s` above the queue's longest job
  runtime, or a long job gets reclaimed mid-flight and re-dispatched). The poller and GC jobs are
  installed **only when a durable queue is declared** — pure-memory and no-queue apps install
  nothing.
- **Priority** (`high`/`normal`/`low`) is a per-queue property. A worker bound to several queues
  drains them in strict priority order: all ready `high`-priority jobs first, then `normal`, then
  `low`.
- **Retry/backoff**: on a retryable failure the durable job's `attempts` is bumped and its next
  run is pushed out by the queue's backoff (`fixed` or `exponential`, with optional jitter, capped
  at `max_ms`); exhausting `max_attempts` marks it `failed` and fires your `.onError` handler
  (phase `.job`). Memory jobs retry in-process the same way.
- **Caveat:** durable workers **poll** (roughly every scheduler tick, ~0.5s), so durable jobs
  drain with low but non-zero latency; the scheduler is single-process.

## Outbound webhooks

`ctx.http()` is a one-shot client — fire-and-handle-the-result yourself. `ctx.webhook()` is its
**managed, retrying** counterpart: it serializes `payload` to JSON, enqueues a background
`"webhook"` job (a built-in queue kind, like `"mail"`), and a worker POSTs it with automatic
retries and back-off.

```zig
try ctx.webhook("https://hooks.example.com/booking", .{
    .event = "booking_confirmed",
    .id    = booking_id,
}, .{
    .queue   = "outbound",          // null → the always-present "default" queue
    .retries = 5,                    // max delivery attempts (1 = no retry)
    .backoff = .exponential,         // .fixed | .exponential (queue back-off math)
    .timeout_s = 10,                 // per-attempt request timeout
    .sign    = .{ .secret = "whsec_…" }, // optional HMAC-SHA256 body signature
    // .idempotency = true,          // default: stable Idempotency-Key across retries
});
```

**Response classification.** A `2xx` is delivered. A **network/transport error, any `5xx`, or a
`429`** (honoring an integer `Retry-After` in preference to the configured back-off) is
**retryable** up to `retries`. **Any other `4xx`** (and `1xx`/`3xx`) is **terminal** — retrying is
pointless. When delivery is terminally rejected **or** attempts are exhausted, the framework fires
your `.onError` hook with phase **`.webhook`**; the job itself then succeeds so the queue does not
double-retry.

**Signing (`opts.sign`).** Each attempt adds `X-Signature: hex(HMAC-SHA256(secret,
"<timestamp>.<body>"))` and `X-Webhook-Timestamp: <unix>`. The timestamp is bound into the signed
string (fresh per attempt) so a captured request cannot be replayed indefinitely.

**Idempotency (`opts.idempotency`, default on).** A single `Idempotency-Key` is minted **once** at
enqueue time and frozen onto the (durable) job row, so every retry — and any at-least-once replay
after a crash — reuses the same key, letting the receiver dedupe. TLS verification is always on.

> Worker-stall caveat: retries back off by **sleeping in the worker thread** for the full retry
> duration. Under the default single-worker topology a slow or failing endpoint therefore stalls
> draining of **every** queue (including `"mail"`). For production, give webhooks a **dedicated
> queue + worker** so their backoff never blocks other jobs —
> `.queues = .{ .webhooks = .{ .backend = .durable } }` plus a worker bound to it
> (`.workers = .{ .hooks = .{ .queues = .{"webhooks"} } }`), then pass `.queue = "webhooks"`.

> Security note: a **durable**, **signed** webhook persists the signing secret inside the
> `_queue_jobs.payload` column (your own DB). Prefer a `memory` queue, a short `done_ttl_s`, or
> DB-at-rest encryption if that is a concern. TLS verification is always on.

## Built-in job kinds

The framework registers built-in job kinds on this same engine, so both ride your `.queues`
config: `"mail"` backs [`ctx.mail().enqueue`](./email.md) (deserializes a `MailMessage` payload and
delivers it), and `"webhook"` backs `ctx.webhook()` above. Both are reached via their respective
helper, not the compile-checked `Job` enum, which reflects only your declared `.jobs`.

## Reference

- [Background jobs & queues (§7b)](./framework.md#7b-background-jobs--queues-queues--workers--jobs)
- [ctx.webhook()](./framework.md#ctxwebhook--managed-outbound-webhooks-144)
- [Scheduled jobs (§7)](./framework.md#7-scheduled-jobs-cron--jobs)
- [Email guide](./email.md)
