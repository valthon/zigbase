### Fixes
- `dumpload.planCreateOrder` (the `migrate load` dependency-order planner) leaked its Kahn-algorithm `placed` scratch buffer on every call. Always masked by the migration's request arena; now freed explicitly.
- `schema_dump.pgColumnType`'s array-type branch (Postgres schema dump, `_<udt>` columns) leaked the base type string it formats into the final `<base>[]` result. Always masked by the per-dump scratch arena; now freed explicitly.

### Internal
- Made `ddl.createTableSql`/`createIndexSql`/`rebuildPlan`/`rebuildPlanPg` self-freeing (allocator ownership contract 1): every intermediate fragment (quoted idents, column defs, allocPrint'd clauses) is now scratch on a function-local arena, and `rebuildPlan`/`rebuildPlanPg` free already-built statements on a mid-loop error. Only the final SQL string (or, for the rebuild planners, each individually-owned statement) escapes on the caller allocator. Correctness/contract only — production still calls these under a per-operation arena.
- Made `schema_dump.pgBaseType`'s fixed-keyword branches (e.g. `"bigint"`, `"integer"`) return an owned dupe instead of a static literal, so every `pgColumnType`/`pgBaseType` result is uniformly caller-owned and freeable the same way.
- Made `framework.liveEncryptedCollection` self-freeing: it now frees the `collections.list` graph it scans and returns an owned dupe of the matched collection's name, rather than an implicit reliance on the caller having passed an arena.
- Converted all 17 arena-masked tests across `ddl.zig` (9), `dumpload.zig` (4), `framework.zig` (1), and `schema_dump.zig` (3) to the raw leak-detecting `std.testing.allocator`, dropping all four allocator-contract allowlist entries.
