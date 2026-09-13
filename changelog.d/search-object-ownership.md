### Fixes

- Additive searchable fields are reconciled after physical column creation.
  PostgreSQL search rejects registry/schema shadows and temporary probe collisions;
  destructive generated-column changes fail closed when user triggers may depend
  on them, without blocking unchanged search or missing-index repair.

- Search provisioning now verifies shared catalog ownership before changing SQLite FTS5 or PostgreSQL search objects, preserving application data on reserved-name collisions. Reconciliation is transactional and still repairs proven engine indexes.

### Breaking

- PostgreSQL generated search columns without the engine ownership comment now refuse startup with `Conflict` instead of being automatically dropped and rebuilt. Inspect and explicitly migrate legacy or application-owned objects before retrying.
