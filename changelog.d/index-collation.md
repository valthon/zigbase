### Features

- **Comptime index collation + partial predicates** — `schema.Index` gains `collation` (`.binary` default / `.nocase`, applied per indexed column) and an optional `where: ?[]const u8` partial-index predicate. Case-insensitive indexes (`CREATE INDEX ... ("email" COLLATE NOCASE)`) and conditional-unique indexes (`... WHERE deleted_at IS NULL`) are now expressible in the comptime `.collections` schema and emitted in the generated `CREATE INDEX` DDL, instead of requiring an out-of-band raw-SQL bootstrap. Defaults preserve existing DDL and JSON round-trip behavior.
