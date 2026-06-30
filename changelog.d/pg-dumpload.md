### Features

- Added a **`migrate-db` CLI subcommand** that copies an existing SQLite-backed instance into a fresh PostgreSQL database — schema **and** data (#159, PR-9): `zigbase migrate-db --from ./zb_data/data.db --to "postgres://…"`. Highlights:
  - **Provisions the equivalent schema** on the target via the same code paths the server uses: runs the system migrations, then creates every collection's record table (including runtime-created collections, with their indexes and relation foreign keys) from the source's `_collections` metadata.
  - **Bulk-loads every system + record table atomically** — the whole load runs in one transaction, so a mid-migration failure rolls the target back to a clean state (schema present, zero migrated rows) rather than leaving it half-populated.
  - **Preserves record ids, timestamps, and `_collections` metadata** (collection ids survive verbatim) and **carries encrypted-field envelopes byte-for-byte** — ciphertext is never decrypted/re-encrypted, so no `ZIGBASE_FIELD_KEY` is passed to the tool and the same key reads the data on Postgres afterward.
  - **Resets the analytics rollup watermarks** so rollups recompute against the target's regenerated `_seq` (a verbatim-copied watermark would otherwise silently stop counting events post-migration).
  - **Verifies integrity**: refuses a non-empty target unless `--force`, reports per-table row counts measured on the **target**, and fails loud on any source/target count mismatch.
  - Present in every binary, but the PostgreSQL side requires a `-Dpostgres` build — a stock binary fails with a clear error rather than silently no-op'ing.
  - Does **not** copy the target's freshly-applied `_migrations` ledger or the SQLite-only FTS5 shadow tables; the collection's `.searchable` metadata is preserved so the Postgres full-text index reprovisions on the next `zigbase serve`. See the "Migrating an existing SQLite instance to Postgres" guide in `docs/framework.md`.

### Internal

- Live `-Dpostgres` round-trip tests (`src/backend/postgres/dumpload_pg_test.zig`, skip when no PG): a SQLite instance with two related collections, an encrypted field, and a system-table row migrates into a throwaway Postgres schema — asserting identical per-table row counts, that the encrypted envelope still decrypts, that the relation FK is enforceable on Postgres, and that ids/metadata are preserved; plus an injected mid-load failure that rolls the whole load back to zero migrated rows. Backend-neutral tests in `src/dumpload.zig` cover the rollup-watermark reset and that per-table report counts equal the real target counts.
