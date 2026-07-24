### Fixes
- Fixed a memory leak on the record read path: when an encrypted field failed to decrypt part-way through building a row (fail-closed `error.BadEnvelope`), `records.get`/`getAtRest`/`create`/`update`/`list` leaked the partially-decoded record. `rowToObject`/`rowToObjectAtRest` now free the partial record on a mid-row read error. The same functions also leaked a hidden field's decoded value (read but never stored); that value is now freed too. Both matter for a framework consumer that calls these APIs with a plain (non-arena) allocator.

### Internal
- Un-masked the `src/records.zig` get/create/update/delete, field-validation, `gcExpiredRecords`, TTL read-exclusion, and encrypted fail-closed tests: they now run under the raw leak-detecting `std.testing.allocator` instead of wrapping it in an arena (records are freed via `records.freeRecord`, the owned `last_errors` slice is freed on the validation-error path, and collections via `Collection.deinit`).
