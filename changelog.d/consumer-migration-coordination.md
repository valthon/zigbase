### Features

- Coordinate PostgreSQL consumer migration application and rollback across replicas, including non-transactional callbacks, while preserving per-migration commits. Requires session-affine connections; existing caller transactions are refused without modifying them.
