### Fixes

- Durable queue enqueue, claim, completion, cancellation, reclaim, and cleanup statements now use PostgreSQL-correct parameters and timestamp expressions.
- PostgreSQL durable queue workers lock and skip already-claimed rows across instances; expired handlers cannot overwrite a newer claim's completion or retry state.
- Schedulers with more than 256 simultaneously due jobs leave overflow jobs eligible for the next tick instead of stranding them as running.

### Changed

- Durable queue rate ceilings are shared through database-backed integer-second windows (migration `0025_queue_rates`; stop older workers before applying it). Claims and their rate charge commit atomically, and restarting a process no longer resets the current window's budget. Idle polls do not rewrite the rate window.
