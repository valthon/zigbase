### Features

- Coordinate PostgreSQL consumer migration application and rollback across replicas, including non-transactional callbacks, while preserving per-migration commits. Requires session-affine connections and now verifies it: an unlock the connection does not own fails with `MigrationLockSessionLost` rather than passing silently. Existing caller transactions are refused without modifying them, and a callback that leaves a transaction open stops the batch at that migration instead of at the end of it.
