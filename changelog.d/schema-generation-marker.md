### Fixes

- **A running server now notices collection changes made by another process.** `zigbase migrate`,
  `zigbase import`, and `zigbase migrate-db` mutate a data dir that a server may be serving from,
  but the collection-metadata cache had no TTL and was invalidated only by this process's own REST
  DDL — so the server kept serving stale definitions (stale access rules included) until it was
  restarted. Because *negative* lookups were cached too, a newly created collection kept returning
  404 rather than merely looking out of date. A one-row `_schema_state` generation marker is now
  bumped by every engine write to `_collections`, inside that write's own transaction, and a
  background observer drops the cache within 5 seconds of the value changing. No new config key and
  no new environment variable.
- Hand-written metadata SQL (e.g. `UPDATE "_collections" …` via `ctx.records().queryAs()`) can
  announce itself with the new `ctx.markSchemaChanged()` / `tx.markSchemaChanged()`; see
  [framework.md](docs/framework.md#ctxmarkschemachanged--announce-a-hand-written-metadata-change).
- `zigbase migrate-db` no longer copies the source's `_migrations`-adjacent bookkeeping into the
  target's schema-generation marker, which could otherwise move a live target's counter backwards
  onto a value observers had already seen.
