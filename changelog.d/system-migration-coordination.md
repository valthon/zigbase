### Fixes
- Coordinate public ledger bootstrap used by migration status, rollback, and doctor too; diagnose caller-owned transaction refusal explicitly without changing caller state.
- Serialize built-in migrations across concurrent PostgreSQL startups, including fresh-ledger creation and applied-state rechecks. Transaction-scoped locks release on success, rollback, and disconnect; SQLite also checks applied state under its writer lock.
