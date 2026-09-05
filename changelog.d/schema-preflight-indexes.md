### Fixes
- Reconcile index-only comptime schema changes transactionally without rebuilding tables or removing migration-owned indexes.
- Validate access-rule field and relation references before schema apply (including dry runs) and REST collection mutations, using the complete prospective schema so forward relations and newly added fields work.

### Breaking
- Comptime `.indexes` is authoritative on startup, including its empty default: metadata-declared indexes absent from code are removed and each DDL operation is logged. Failed builds or conflicting external names refuse startup with the collection and index identified. Equivalent ordinary migration-created indexes are adopted; unsupported external definitions require an explicit migration.
