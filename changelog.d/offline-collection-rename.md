### Features

- Explicit offline `Migrator.renameCollection` preserves collection/field/record IDs,
  relations, indexes, search, and persistent auth references atomically. Requires all
  processes stopped and compiled name references updated; no old URL/topic aliases.
  File-bearing schemas and pending storage dependencies fail closed pending the
  immutable storage namespace follow-on.

### Changed

- Cursor fingerprints bind collection identity, name, and an engine-owned monotonic
  rename epoch, so reversal cannot revive revoked cursors. Existing cursors issued
  before this upgrade must be discarded and pagination restarted. Auth collection
  renames rotate signing keys and revoke sessions/challenges, including on reversal.
- Rename preflight verifies generated search/index ownership before touching DDL;
  PostgreSQL auth indexes retain their identity without redundant indexes after
  provisioning. Failed rollback cleanup terminates the offline process to prevent
  reuse of an unsafe writer.
- Renames reject temporary relation shadows, ambiguous relation IDs/names, and
  destination search-column/shadow-table collisions. Auth key rotation reads
  bounded keyset batches instead of retaining the entire principal collection.
- Dangling destination-name relation metadata and SQLite foreign keys must be
  repaired explicitly before renaming; existing links cannot silently acquire
  the renamed collection as their target.
