### Features

- Expired-session garbage collection for `.session_store = .table` (#114). Enabling the
  table-mode session store now auto-installs a framework-internal recurring job that deletes
  expired `_sessions` rows in bounded batches on the writer — no opt-in required. The default
  cadence is hourly; override it with `App(.{ .session_store = .table, .session_gc_cron = "…" })`
  (UTC, minute-granularity cron syntax). Nothing is installed in the default `.epoch` mode (no
  job, no timer — the zero-overhead guarantee is preserved).
