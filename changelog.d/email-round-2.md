### Features

- Scheduled sends: `ctx.mail().deliverAt(msg, .{ .at | .delay_s })` returns a cancellable job id, `ctx.mail().cancel(id)` calls a pending send off, and `sendBulk` accepts `.at` — the documented drip-sequence primitives.
- Per-queue rate throttling: durable queues accept `.rate = .{ .per_second = N }` — a token-bucket ceiling enforced at claim time (e.g. match SES's 14 msg/s).

### Changed

- `durable.enqueue` now returns the generated job id, and the queue GC reaps `canceled` jobs (internal signature change, pre-1.0).
