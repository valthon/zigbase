### Features

- `migrate-db` can now provision a schema with circular relations onto a Postgres target: cycle-edge foreign keys are omitted from the initial `CREATE TABLE` (Postgres cannot create tables with circular inline `REFERENCES` in any order) and added back afterwards as `DEFERRABLE INITIALLY IMMEDIATE` constraints. Previously this schema shape failed outright during provisioning. SQLite targets are unaffected (its inline FK DDL already tolerates cycles).
