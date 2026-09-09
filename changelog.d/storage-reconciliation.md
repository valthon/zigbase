### Features

- Opt-in `files reconcile` (`-Dfile-inventory=true`) previews bounded orphan candidates and supports explicit offline deletion for built-in local storage with SQLite. Apply refuses active cooperating apps, locks database writes, and rechecks object identity, age and physical references before each unlink. S3, PostgreSQL and custom storage are refused; older/external writers must be stopped and the storage root dedicated to one database. Unknown metadata is retained; partial deletion failures exit nonzero and cannot roll back filesystem changes.

### Changed

- Every booted app using built-in local storage now holds one shared maintenance-lock descriptor until shutdown, even without inventory enabled or with `serve --ignore-lock`; there is no per-request lock operation. The permanent `storage/.zigbase-maintenance.lock` must not be removed or replaced and is excluded from inventory. Offline reconciliation requires its exclusive lease.
