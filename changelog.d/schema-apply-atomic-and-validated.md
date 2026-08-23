### Breaking

- A field whose name the engine reserves (`id`, `created`, `updated`, `email`, `username`, `passwordHash`, `tokenKey`, `verified`, `token_epoch`, case-insensitively) is now **refused** on a `base` or `view` collection instead of being silently dropped — `POST`/`PATCH /api/collections` answer `400 validation_reserved_name`, and `zigbase schema apply` refuses the document. A schema that previously "applied" while quietly discarding such a column now fails loudly; rename the field. `auth` collections are unchanged: their own injected system fields are still ignored on input, so a client can still write back a collection document it just read.

### Fixes

- `zigbase schema apply` no longer silently discards a reserved-named field on an ordinary table. A `contacts` collection with an `email` field used to migrate to a `contacts` collection *without* one — exit 0 from `apply`, the field simply absent from `schema dump`, and a subsequent `import` reporting `1 created, 0 failed` while throwing that column's values away. (#382)
- `zigbase schema apply --dry-run` now runs the same validation the real apply runs, so a rehearsal refuses exactly what a run refuses. A document carrying an identifier-invalid field name (`_draft`), a reserved name, an unsatisfiable date range, or an encrypted field with no `ZIGBASE_FIELD_KEY` passed the dry run with exit 0 and then failed the real one. Every problem in the document is now reported at once, on stderr, with its error code. (#383)
- `zigbase schema apply` is now **atomic across collections**. All three passes run in one transaction, so a document that fails on its fourth collection no longer leaves the first three behind — previously the operator was left in a state that was neither the old one nor the new one, and had to work out by hand what the failed attempt had done. The emitted `applied` list is empty on a failure. (#383)
- Freeing a non-injected `auth` collection (the shape `schema.parseCollectionInput` returns) no longer panics with an out-of-bounds slice. `Collection.deinit` assumed every auth collection carried the engine's injected system-field prefix; `schema apply` reached the other shape whenever a schema document paired an auth collection having fewer than six fields with a malformed one.

### Internal

- `collections.create`/`update`/`delete`/`updateRules` join a caller's open transaction with a `SAVEPOINT` instead of opening their own, via a new `db.Db.inTransaction()` seam (`sqlite3_get_autocommit` on SQLite, the `ReadyForQuery` transaction status on PostgreSQL). `collections.update` also skips its `PRAGMA foreign_keys` toggle when a caller owns the transaction, since SQLite ignores that pragma inside one — the caller sets it outside instead.
