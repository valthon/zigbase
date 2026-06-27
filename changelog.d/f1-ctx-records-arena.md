### Fixes

- `ctx.records()` now allocates its results on a per-invocation arena instead of
  the long-lived process allocator. This fixes a heap leak that grew per request
  on routes and unboundedly for per-minute cron jobs. Route results live on the
  request arena; job, `App.submit`, and lifecycle-hook results live on a
  per-invocation arena freed when the invocation ends. No API change.
