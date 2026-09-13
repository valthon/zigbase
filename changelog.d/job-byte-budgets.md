### Features
- Add independent `.admission.max_job_bytes` under `-Dcoordinated-admission=true` to bound retained memory-job payload and `app.submit` name copies across queued/running tasks and retries, without requiring HTTP admission. Reservations precede copying and return on cleanup/errors; byte exhaustion returns `error.QueueFull`. Diagnostics and the offline resource envelope report the budget; byte-only mode reports a nullable HTTP limit and zero HTTP counters. This excludes pre-enqueue serialization, inline borrowed payloads, handler allocations and total RSS.

### Fixes
- Exact `GET /api/health` no longer parses or rejects a multipart request body in any build; the liveness probe ignores bodies as documented.

### Breaking
- `admission.Config.max_requests` (including `App.admission_config`) and `admission.Snapshot.limit` (including `Runtime.admission.snapshot()`) are now `?u32`, not `u32`. Handle `null` as no HTTP cap with optional capture; use `.?` only when your configuration guarantees an HTTP cap. `/api/admission/stats` likewise reports `limit: null` in byte-only mode. Omit `.max_requests`, rather than setting it to zero, to disable HTTP admission while retaining `.max_job_bytes`.
