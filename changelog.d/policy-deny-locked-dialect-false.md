### Security

- Hardened the fail-closed `deny_locked` authorization floor for Postgres dialect-portability. It
  hardcoded the SQLite-only `0` false-literal (`WHERE 0`), which Postgres rejects
  (`argument of WHERE must be type boolean`); it now uses the dialect's `constFalse()` (`false` on
  Postgres) — the same constant the ability/tenant composition already emits — so the fail-closed
  floor is guaranteed-valid SQL on both backends. (In current code this branch is short-circuited by
  `authorizes` before it reaches a statement, so no live query was affected; the fix hardens the
  path against any evaluator that runs the guard directly.)
