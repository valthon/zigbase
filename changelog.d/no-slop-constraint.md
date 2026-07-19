### Fixes

- A write that violates a database integrity constraint — most commonly a duplicate value on a unique field, such as signing up with an email that is already registered — now returns **409 Conflict** instead of **500 Internal Server Error**. Clients, SDKs, and error monitoring can now tell a routine user conflict apart from a genuine server fault. This applies to record create/update, runtime collection create/update, and WebAuthn credential registration, on both the SQLite and Postgres backends.

### Changed

- The internal database error set gained a distinct `error.Constraint` (SQLite `SQLITE_CONSTRAINT`; Postgres SQLSTATE class 23), raised from the prepared-statement `step()` path instead of collapsing every failure into `error.StepFailed`. Custom routes that let a `ctx.records()` write propagate now surface a constraint violation as 409 automatically. Framework consumers who matched on `error.StepFailed` for a unique-violation race should match `error.Constraint`. The `exec()`/COMMIT path (including deferred-constraint failures) is unchanged and still reports `error.ExecFailed`.
