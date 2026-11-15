### Fixes
- On PostgreSQL, durable queues now stamp claims, run the reclaim sweeps (the poller's and the hourly `_queue_gc`), schedule retries and charge `.rate` windows on the database server's clock instead of each app host's clock. A job enqueued for now or with a delay is due that long after the server's current second, and an absolute time (`deliverAt`'s `.at`, `sendBulk`'s `.at`) is due when the server's clock reaches it. An instance whose clock ran ahead no longer resets other instances' claims before `visibility_timeout_s` has passed, which had run their jobs twice (#491). Upgrade every coordinated instance together: older binaries still use their own host clock.

### Changed
- The docs now say how a wall-clock step affects durable claims and `.distributed` leases: a forward step of the database clock (the server's on PostgreSQL, the host's on SQLite) can expire them early. Generation fencing still applies and delivery stays at-least-once (#492).
