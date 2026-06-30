### Internal

- PostgreSQL backend, deterministic test-clock parity (#159, PR-7): the
  `ZIGBASE_FAKE_NOW` frozen clock now freezes the **SQL** clock on the Postgres arm too,
  matching SQLite. The two SQLite-only shims have no remote-server analog —
  `src/clock_sql.zig` shadows SQL date/time *functions* and `src/clock_vfs.zig` is a SQLite
  VFS overriding `xCurrentTime` — so their effect is reproduced on Postgres with a single
  **session-level `now()` override** (`src/backend/postgres/clock.zig`): when a freeze is
  active, every connection (opened through `pg.Db.open`, covering the pool's writer and all
  readers) installs a `zigbase_frozen.now()` wrapper returning the frozen instant and appends
  `zigbase_frozen, pg_catalog` to its `search_path` so unqualified `now()` resolves to the
  wrapper (Postgres searches `pg_catalog` implicitly-first unless it is named explicitly
  later). This freezes the dialect's `now()`/`nowIso8601Expr` (record autodate stamps,
  KV/`_migrations`/`_collections` metadata timestamps) and a consumer's raw `now()` alike,
  while leaving table/type resolution and object creation targeting the original first schema.
  Gated by the same comptime `dev_clock` build option as the SQLite shims (comptime-dead +
  never installed on a production build); the SQLite `clock_sql`/`clock_vfs` paths are
  unchanged. This is the prerequisite for the existing `ZIGBASE_FAKE_NOW` determinism tests to
  run on the `-Dpostgres` CI job. Verified end-to-end against a live PostgreSQL: a
  `now()`/`nowIso8601Expr`-stamped column reflects the frozen instant when `ZIGBASE_FAKE_NOW`
  is set, and tracks the real wall clock when it is not.
