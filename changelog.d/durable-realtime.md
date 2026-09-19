### Features

- Add opt-in durable REST record invalidation replay on SQLite and PostgreSQL, with transactionally ordered checkpoints surviving restarts and cross-instance reads, bounded shared retention, and current authorization. Journal failures roll back record writes. Enable with `-Ddurable-realtime=true`; raw SQL, Data facade writes and hook side-writes remain outside capture coverage.
