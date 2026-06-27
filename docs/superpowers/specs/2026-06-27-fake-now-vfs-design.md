# Fake-now VFS: freeze CURRENT_TIMESTAMP + column DEFAULTs (issue #97)

## Problem

Theme C (#84, `src/clock_sql.zig`) freezes a consumer's raw `datetime('now')` /
`unixepoch('now')` / `strftime(…, 'now')` / `date` / `time` / `julianday` under
`ZIGBASE_FAKE_NOW` by shadowing the SQL date/time *functions* on every connection.

But SQLite's `CURRENT_TIMESTAMP` / `CURRENT_TIME` / `CURRENT_DATE` keywords (and any
column `DEFAULT CURRENT_TIMESTAMP`) do **not** go through the SQL-function layer. They
read the clock through the VFS method `xCurrentTimeInt64` (falling back to
`xCurrentTime`). So they still read the OS clock even when time is frozen — making a
table with `DEFAULT CURRENT_TIMESTAMP` impossible to snapshot-test deterministically.
This was explicitly listed as out-of-scope in `KNOWN_LIMITATIONS.md`. #97 closes it.

## Approach: wrap the default VFS, override only the time hooks

Register a custom `sqlite3_vfs` named `zigbase_frozen` that is a **byte-for-byte copy of
the default VFS struct**, with exactly three differences:

1. `zName` = `"zigbase_frozen"` (only ever reported back via file-control; harmless).
2. `xCurrentTimeInt64` → our override.
3. `xCurrentTime` → our override.

Every other field — `pAppData`, `szOsFile`, `mxPathname`, `iVersion`, and **all** the
I/O method pointers (`xOpen`, `xDelete`, `xAccess`, `xFullPathname`, `xRandomness`,
`xSleep`, dl*, syscall*) — is the genuine default-VFS value. Because the copy preserves
those, the real unix `xOpen` etc. run unchanged: they read `pVfs->pAppData` (the locking
finder), `pVfs->szOsFile`, `pVfs->mxPathname` from our copy, which equal the originals.
No file I/O is re-implemented. WAL, temp files, shared-memory all keep working because
those live in `sqlite3_io_methods` (set by the real `xOpen`), untouched here.

### Why copying the struct is safe (verified against the amalgamation)

- `unixFile` stores the `sqlite3_vfs*` it was created with and later reads only
  `pVfs->zName` (reporting) and `pVfs->mxPathname` (temp-name length) from it — both
  preserved by the copy.
- `unixOpen` dereferences `pVfs->pAppData` for the locking-style finder and
  `pVfs->szOsFile` for allocation — both preserved.
- The VFS is registered **non-default** (`makeDflt = 0`); connections opt in by passing
  the name as the `zVfs` argument of `sqlite3_open_v2`. The process default VFS is
  untouched, so anything that opens without a name (e.g. the `clock_sql` helper
  connection) is unaffected.

### The time override

`xCurrentTimeInt64(_, out)` returns Julian-day **milliseconds**:
`out = 210866760000000 + frozen_unix*1000` when a freeze is active, where
`210866760000000` is the unix epoch (JD 2440587.5) in ms. Otherwise it delegates to the
real VFS's `xCurrentTimeInt64` (passing the *real* VFS pointer, kept in a global), with a
fallback to `xCurrentTime` for a hypothetical iVersion-1 base VFS.

`xCurrentTime(_, out)` returns the Julian **day** as a double:
`out = 2440587.5 + frozen_unix/86400.0` when frozen, else delegates.

Both read `clock.frozenUnix()` *per call*, so they reflect whatever was installed at
startup (`clock.install`) — registration order vs. freeze-install order does not matter.

## Production gate (hard requirement)

`vfsName()` opens with `if (comptime !clock.enabled) return null;`. `clock.enabled` is the
comptime `dev_clock` build option (off in every release build). On a prod build:

- `vfsName()` folds to `null`, so `sqlite3_open_v2` is called with `zVfs = null` exactly
  as today — the OS default VFS, byte-for-byte unchanged.
- `ensureInstalled`, the wrapper struct, and both override callbacks are comptime-dead
  and eliminated. No custom VFS is ever registered; `sqlite3_vfs_find("zigbase_frozen")`
  returns null.

## Integration

`db.zig` opens connections in two places — `Db.open` (writer + `:memory:`) and
`Pool.openReader` (readers). Both currently pass `null` as the `zVfs` arg. Change both to
pass `clock_vfs.vfsName()`. `vfsName()` lazily + idempotently registers the wrapper
(spin-mutex guarded, matching `clock_sql`'s helper) on first dev-build call and returns
the name; in prod it is a comptime `null`.

## Tests (`src/clock_vfs.zig`, registered in `root.zig`)

- **frozen (dev only):** open via `Db.open`; `SELECT CURRENT_TIMESTAMP` == frozen
  formatted instant; a table with `DEFAULT CURRENT_TIMESTAMP` inserts the frozen instant;
  `CURRENT_DATE`/`CURRENT_TIME` frozen too.
- **no freeze (dev):** `CURRENT_TIMESTAMP` tracks a plausible recent wall-clock value
  (delegation works).
- **prod gate:** skipped unless `-Ddev-clock=false`; asserts `vfsName()` is null,
  `sqlite3_vfs_find("zigbase_frozen")` is null, and `CURRENT_TIMESTAMP` is wall-clock.
- The existing file-backed + WAL pool tests already exercise the wrapper for real I/O on
  a dev/test build, proving the copy didn't break normal operation.
