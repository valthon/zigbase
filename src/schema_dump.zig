//! Live-database schema dump (`zigbase migrate dump`, migrations Piece C). Introspects the LIVE
//! database and produces a canonical, dialect-native `structure.sql` — for inspection, review
//! diffing, and fast test-DB setup. It is NOT a schema source and is never loaded at boot (that is
//! `.collections`); it is a snapshot of what the running database actually contains.
//!
//! **Determinism is the whole point** (the output is meant to be diffed): every query orders its
//! rows deterministically and NOTHING volatile (timestamps, sequence positions, oids) leaks into the
//! text. Two dumps of the same database are byte-identical.
//!
//! Both backends emit the DDL themselves — SQLite reads the exact stored `sqlite_master.sql`, and
//! Postgres reconstructs from the system catalogs (`information_schema`, `pg_constraint` via
//! `pg_get_constraintdef`, `pg_indexes.indexdef`). **No external `pg_dump` binary is ever invoked.**
//!
//! After the structure, the applied-migration ledger (`_migrations`) is emitted as a single INSERT so
//! a restored dump lands at the same migration state. Emitted string literals double single quotes
//! (standard SQL escaping) so DB-sourced values cannot break out of the literal.

const std = @import("std");
const db = @import("db.zig");
const Migrator = @import("migrator.zig").Migrator;

/// Introspect the live database behind `conn` and return a canonical `structure.sql` string,
/// allocated from `alloc` (caller owns it). `dialect` selects the reconstruction strategy; it must
/// match `conn`'s backend (callers pass `db.dbDialect(conn)`). On Postgres this dumps the `public`
/// schema; `schemaDumpForSchema` targets a different schema (used by isolated tests).
pub fn schemaDump(alloc: std.mem.Allocator, conn: *db.Db, dialect: db.Dialect) ![]const u8 {
    return schemaDumpForSchema(alloc, conn, dialect, "public");
}

/// As `schemaDump`, but the Postgres reconstruction targets `pg_schema` instead of `public`. The
/// SQLite path ignores `pg_schema` (SQLite has no schema namespace). Exposed so schema-isolated
/// tests can dump their throwaway `CREATE SCHEMA`.
pub fn schemaDumpForSchema(alloc: std.mem.Allocator, conn: *db.Db, dialect: db.Dialect, pg_schema: []const u8) ![]const u8 {
    // Scratch arena for per-fragment formatting; only the final buffer is handed back on `alloc`.
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // Deterministic header — NO timestamp (would defeat diffing).
    try out.appendSlice(alloc, switch (dialect.kind) {
        .sqlite => "-- ZigBase schema dump (sqlite)\n",
        .postgres => "-- ZigBase schema dump (postgres)\n",
    });

    switch (dialect.kind) {
        .sqlite => try dumpSqlite(alloc, a, conn, dialect, &out),
        .postgres => try dumpPostgres(alloc, a, conn, dialect, pg_schema, &out),
    }

    try appendLedger(alloc, a, conn, dialect, &out);

    return try out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// SQLite — the stored DDL is exact and free.
// ---------------------------------------------------------------------------

/// Emit every user object's stored `CREATE …` verbatim, tables before indexes then by name. The
/// `sqlite_master.sql` text is authoritative (it is what SQLite parsed) and includes `_migrations`,
/// `_collections`, and any migration-created objects — the true live structure.
fn dumpSqlite(alloc: std.mem.Allocator, a: std.mem.Allocator, conn: *db.Db, dialect: db.Dialect, out: *std.ArrayList(u8)) !void {
    var m = Migrator{ .db = conn, .dialect = dialect, .arena = a, .io = undefined };
    var st = try m.prepare(
        \\SELECT "sql" FROM "sqlite_master"
        \\WHERE "sql" IS NOT NULL AND "name" NOT LIKE 'sqlite_%'
        \\ORDER BY ("type"='index'), "name";
    );
    defer st.finalize();
    while (try st.step()) {
        if (st.isNull(0)) continue;
        try out.appendSlice(alloc, st.columnText(0));
        try out.appendSlice(alloc, ";\n");
    }
}

// ---------------------------------------------------------------------------
// Postgres — reconstruct from the system catalogs (no pg_dump).
// ---------------------------------------------------------------------------

/// Reconstruct `pg_schema`-schema DDL from the catalogs: CREATE TABLEs first (columns from
/// `information_schema.columns`), then ALL constraints as `ALTER TABLE … ADD CONSTRAINT` (so FK
/// ordering can never break), then non-constraint-backing indexes. Every phase is ordered
/// deterministically. The schema name is a bound parameter (never interpolated).
fn dumpPostgres(alloc: std.mem.Allocator, a: std.mem.Allocator, conn: *db.Db, dialect: db.Dialect, pg_schema: []const u8, out: *std.ArrayList(u8)) !void {
    var m = Migrator{ .db = conn, .dialect = dialect, .arena = a, .io = undefined };

    // 1) CREATE TABLE per base table, columns in ordinal order.
    {
        var tbls = try m.prepare(
            \\SELECT "table_name" FROM "information_schema"."tables"
            \\WHERE "table_schema"=?1 AND "table_type"='BASE TABLE'
            \\ORDER BY "table_name";
        );
        defer tbls.finalize();
        try tbls.bindText(1, pg_schema);
        var table_names: std.ArrayList([]const u8) = .empty;
        while (try tbls.step()) {
            try table_names.append(a, try a.dupe(u8, tbls.columnText(0)));
        }
        for (table_names.items) |tname| {
            try emitCreateTable(alloc, a, &m, pg_schema, tname, out);
        }
    }

    // 2) Constraints (PK/UNIQUE/FK/CHECK) via pg_get_constraintdef — the exact DDL — as ALTER TABLE.
    {
        var cons = try m.prepare(
            \\SELECT "t"."relname", "c"."conname", pg_get_constraintdef("c"."oid")
            \\FROM "pg_constraint" "c"
            \\JOIN "pg_class" "t" ON "t"."oid" = "c"."conrelid"
            \\JOIN "pg_namespace" "n" ON "n"."oid" = "t"."relnamespace"
            \\WHERE "n"."nspname" = ?1
            \\ORDER BY "t"."relname", "c"."conname";
        );
        defer cons.finalize();
        try cons.bindText(1, pg_schema);
        while (try cons.step()) {
            const rel = try quoteIdent(a, cons.columnText(0));
            const con = try quoteIdent(a, cons.columnText(1));
            const def = cons.columnText(2);
            try out.appendSlice(alloc, try std.fmt.allocPrint(a, "ALTER TABLE {s} ADD CONSTRAINT {s} {s};\n", .{ rel, con, def }));
        }
    }

    // 3) Indexes via pg_indexes.indexdef, SKIPPING those that back a PK/unique constraint (those
    //    already ship with the constraint above).
    {
        var idx = try m.prepare(
            \\SELECT "indexdef" FROM "pg_indexes"
            \\WHERE "schemaname"=?1
            \\  AND "indexname" NOT IN (
            \\    SELECT "ci"."relname" FROM "pg_constraint" "con"
            \\    JOIN "pg_class" "ci" ON "ci"."oid" = "con"."conindid"
            \\    WHERE "con"."conindid" <> 0 AND "con"."connamespace" = ?1::regnamespace
            \\  )
            \\ORDER BY "tablename", "indexname";
        );
        defer idx.finalize();
        try idx.bindText(1, pg_schema);
        while (try idx.step()) {
            try out.appendSlice(alloc, idx.columnText(0));
            try out.appendSlice(alloc, ";\n");
        }
    }
}

/// Build `CREATE TABLE "t" (\n  "col" TYPE [NOT NULL] [DEFAULT …],\n  …\n);` from
/// `information_schema.columns`, ordered by `ordinal_position`. Constraints are added separately
/// (phase 2), so this emits column definitions only.
fn emitCreateTable(alloc: std.mem.Allocator, a: std.mem.Allocator, m: *Migrator, pg_schema: []const u8, table: []const u8, out: *std.ArrayList(u8)) !void {
    var st = try m.prepare(
        \\SELECT "column_name", "is_nullable", "column_default", "udt_name",
        \\       "character_maximum_length", "numeric_precision", "numeric_scale"
        \\FROM "information_schema"."columns"
        \\WHERE "table_schema"=?1 AND "table_name" = ?2
        \\ORDER BY "ordinal_position";
    );
    defer st.finalize();
    try st.bindText(1, pg_schema);
    try st.bindText(2, table);

    try out.appendSlice(alloc, try std.fmt.allocPrint(a, "CREATE TABLE {s} (\n", .{try quoteIdent(a, table)}));
    var first = true;
    while (try st.step()) {
        const name = try quoteIdent(a, st.columnText(0));
        const not_null = std.mem.eql(u8, st.columnText(1), "NO");
        const udt = st.columnText(3);
        const char_max: ?i64 = if (st.isNull(4)) null else st.columnInt(4);
        const num_prec: ?i64 = if (st.isNull(5)) null else st.columnInt(5);
        const num_scale: ?i64 = if (st.isNull(6)) null else st.columnInt(6);
        const type_str = try pgColumnType(a, udt, char_max, num_prec, num_scale);

        if (!first) try out.appendSlice(alloc, ",\n");
        first = false;
        try out.appendSlice(alloc, try std.fmt.allocPrint(a, "  {s} {s}", .{ name, type_str }));
        if (!st.isNull(2)) {
            // column_default is a catalog expression (e.g. `nextval(...)`, `now()`); emit verbatim.
            try out.appendSlice(alloc, try std.fmt.allocPrint(a, " DEFAULT {s}", .{st.columnText(2)}));
        }
        if (not_null) try out.appendSlice(alloc, " NOT NULL");
    }
    try out.appendSlice(alloc, "\n);\n");
}

/// Map a Postgres `udt_name` (the catalog's internal type name) to a canonical, human SQL type,
/// honoring `character_maximum_length` for char/varchar and `numeric_precision`/`numeric_scale` for
/// numeric. ARRAY columns are catalogued with a leading-underscore udt (e.g. `_int4` for
/// `integer[]`); those are reconstructed by mapping the base type and appending `[]` (element
/// modifiers like length are not carried in `information_schema.columns`, so `integer[]`/`text[]` is
/// the correct form). Any unknown/custom type is QUOTED (`pgBaseType` → `quoteIdent`), so a
/// migration-created type with an adversarial name cannot break out of the column def on replay.
fn pgColumnType(a: std.mem.Allocator, udt: []const u8, char_max: ?i64, num_prec: ?i64, num_scale: ?i64) ![]const u8 {
    if (udt.len > 1 and udt[0] == '_') {
        // Array element modifiers are not available on the array column row; use the bare base type.
        const base = try pgBaseType(a, udt[1..], null, null, null);
        return try std.fmt.allocPrint(a, "{s}[]", .{base});
    }
    return try pgBaseType(a, udt, char_max, num_prec, num_scale);
}

/// Canonicalize a single (non-array) Postgres `udt_name`. Known types map to their human SQL
/// keyword; an UNKNOWN/custom type is returned QUOTED (`quoteIdent`) — a quoted type name is valid
/// DDL if the type exists, and quoting closes the only path by which a DB-derived value reached the
/// CREATE TABLE output unescaped. (The dump does not recreate custom types — see the docs caveat.)
fn pgBaseType(a: std.mem.Allocator, udt: []const u8, char_max: ?i64, num_prec: ?i64, num_scale: ?i64) ![]const u8 {
    const eql = std.mem.eql;
    if (eql(u8, udt, "int8")) return "bigint";
    if (eql(u8, udt, "int4")) return "integer";
    if (eql(u8, udt, "int2")) return "smallint";
    if (eql(u8, udt, "bool")) return "boolean";
    if (eql(u8, udt, "float4")) return "real";
    if (eql(u8, udt, "float8")) return "double precision";
    if (eql(u8, udt, "timestamptz")) return "timestamp with time zone";
    if (eql(u8, udt, "timestamp")) return "timestamp without time zone";
    if (eql(u8, udt, "text")) return "text";
    if (eql(u8, udt, "varchar")) {
        if (char_max) |n| return try std.fmt.allocPrint(a, "character varying({d})", .{n});
        return "character varying";
    }
    if (eql(u8, udt, "bpchar")) {
        if (char_max) |n| return try std.fmt.allocPrint(a, "character({d})", .{n});
        return "character";
    }
    if (eql(u8, udt, "numeric")) {
        if (num_prec) |p| return try std.fmt.allocPrint(a, "numeric({d},{d})", .{ p, num_scale orelse 0 });
        return "numeric";
    }
    return try quoteIdent(a, udt);
}

// ---------------------------------------------------------------------------
// Applied-migration ledger (both backends).
// ---------------------------------------------------------------------------

/// Emit the `_migrations` rows (id ascending → apply order) as ONE `INSERT … VALUES (…), (…);`, with
/// `id` omitted so a restore re-numbers the autoincrement PK. Values are SQL-string-literal escaped
/// (single quotes doubled). If the ledger is empty (or absent), nothing is emitted.
fn appendLedger(alloc: std.mem.Allocator, a: std.mem.Allocator, conn: *db.Db, dialect: db.Dialect, out: *std.ArrayList(u8)) !void {
    var m = Migrator{ .db = conn, .dialect = dialect, .arena = a, .io = undefined };

    // Skip cleanly on a bare DB (no `_migrations` yet). This MUST be an explicit, dialect-aware
    // existence check rather than a `catch return` on the SELECT: on Postgres the extended-query
    // protocol defers relation resolution to EXECUTE, so a missing table errors at `step()`, not
    // `prepare()` — a bare `catch return` on step would also swallow a GENUINE mid-iteration error.
    // With the table confirmed present, `try st.step()` below lets real failures propagate.
    if (!try migrationsTableExists(&m)) return;

    var st = try m.prepare("SELECT \"name\", \"applied_at\" FROM \"_migrations\" ORDER BY \"id\";");
    defer st.finalize();

    var rows: std.ArrayList([]const u8) = .empty;
    while (try st.step()) {
        const name = try sqlLiteral(a, st.columnText(0));
        const at = try sqlLiteral(a, st.columnText(1));
        try rows.append(a, try std.fmt.allocPrint(a, "({s}, {s})", .{ name, at }));
    }
    if (rows.items.len == 0) return;

    try out.appendSlice(alloc, "\n-- applied migrations\n");
    try out.appendSlice(alloc, "INSERT INTO \"_migrations\" (\"name\", \"applied_at\") VALUES\n");
    for (rows.items, 0..) |row, i| {
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, row);
        try out.appendSlice(alloc, if (i + 1 == rows.items.len) ";\n" else ",\n");
    }
}

/// Dialect-aware check for whether the `_migrations` ledger table exists (resolving via the active
/// search_path on Postgres, so an isolated-schema context without the table reports false). Both
/// queries return exactly one row with a `0`/`1` integer, so a genuine query failure still
/// propagates while an absent table is a clean `false` (never an error).
fn migrationsTableExists(m: *Migrator) !bool {
    const sql = switch (m.dialect.kind) {
        // `sqlite_master` lists user tables; EXISTS yields 0/1.
        .sqlite => "SELECT EXISTS(SELECT 1 FROM \"sqlite_master\" WHERE \"type\"='table' AND \"name\"='_migrations');",
        // `to_regclass` returns NULL (never errors) for a name not on the search_path.
        .postgres => "SELECT CASE WHEN to_regclass('_migrations') IS NULL THEN 0 ELSE 1 END;",
    };
    var st = try m.prepare(sql);
    defer st.finalize();
    if (!try st.step()) return false;
    return st.columnInt(0) != 0;
}

// ---------------------------------------------------------------------------
// Escaping helpers.
// ---------------------------------------------------------------------------

/// Wrap `s` as a SQL string literal, doubling any embedded single quotes.
fn sqlLiteral(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(a, '\'');
    for (s) |ch| {
        if (ch == '\'') try buf.append(a, '\'');
        try buf.append(a, ch);
    }
    try buf.append(a, '\'');
    return try buf.toOwnedSlice(a);
}

/// Wrap `s` as a double-quoted SQL identifier, doubling any embedded double quotes.
fn quoteIdent(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(a, '"');
    for (s) |ch| {
        if (ch == '"') try buf.append(a, '"');
        try buf.append(a, ch);
    }
    try buf.append(a, '"');
    return try buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sqlLiteral doubles single quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("'it''s'", try sqlLiteral(arena.allocator(), "it's"));
    try std.testing.expectEqualStrings("'plain'", try sqlLiteral(arena.allocator(), "plain"));
}

test "quoteIdent doubles double quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("\"posts\"", try quoteIdent(arena.allocator(), "posts"));
    try std.testing.expectEqualStrings("\"a\"\"b\"", try quoteIdent(arena.allocator(), "a\"b"));
}

test "pgColumnType maps common udt names canonically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("bigint", try pgColumnType(a, "int8", null, null, null));
    try std.testing.expectEqualStrings("integer", try pgColumnType(a, "int4", null, null, null));
    try std.testing.expectEqualStrings("boolean", try pgColumnType(a, "bool", null, null, null));
    try std.testing.expectEqualStrings("timestamp with time zone", try pgColumnType(a, "timestamptz", null, null, null));
    try std.testing.expectEqualStrings("character varying(255)", try pgColumnType(a, "varchar", 255, null, null));
    try std.testing.expectEqualStrings("character varying", try pgColumnType(a, "varchar", null, null, null));
    try std.testing.expectEqualStrings("numeric(10,2)", try pgColumnType(a, "numeric", null, 10, 2));
    // Array types (leading-underscore udt) reconstruct the base type + "[]".
    try std.testing.expectEqualStrings("integer[]", try pgColumnType(a, "_int4", null, null, null));
    try std.testing.expectEqualStrings("text[]", try pgColumnType(a, "_text", null, null, null));
    try std.testing.expectEqualStrings("bigint[]", try pgColumnType(a, "_int8", null, null, null));
    // Unknown/custom type is QUOTED (not raw), so an adversarial type name cannot break out.
    try std.testing.expectEqualStrings("\"jsonb\"", try pgColumnType(a, "jsonb", null, null, null));
    try std.testing.expectEqualStrings("\"my_enum\"", try pgColumnType(a, "my_enum", null, null, null));
    // A crafted udt_name with an embedded double-quote is escaped (doubled) inside the quotes.
    try std.testing.expectEqualStrings("\"ev\"\"il\"", try pgColumnType(a, "ev\"il", null, null, null));
    // An array of an unknown type quotes the base and appends "[]".
    try std.testing.expectEqualStrings("\"my_enum\"[]", try pgColumnType(a, "_my_enum", null, null, null));
}

test "schemaDump (sqlite) emits CREATE TABLE/INDEX verbatim + the ledger INSERT" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE \"posts\" (\"id\" INTEGER PRIMARY KEY, \"title\" TEXT NOT NULL, \"status\" TEXT);");
    try d.exec("CREATE TABLE \"authors\" (\"id\" INTEGER PRIMARY KEY, \"name\" TEXT);");
    try d.exec("CREATE INDEX \"idx_posts_status\" ON \"posts\"(\"status\");");
    try d.exec("CREATE TABLE \"_migrations\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" TEXT UNIQUE NOT NULL, \"applied_at\" TEXT NOT NULL);");
    // Include an apostrophe in a value to exercise SQL-literal escaping.
    try d.exec("INSERT INTO \"_migrations\" (\"name\",\"applied_at\") VALUES ('0001_init','2020-01-01'),('prov:o''brien','2020-01-02');");

    const dump = try schemaDump(std.testing.allocator, &d, db.dbDialect(&d));
    defer std.testing.allocator.free(dump);

    // Structure statements present.
    try std.testing.expect(std.mem.indexOf(u8, dump, "CREATE TABLE \"posts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "CREATE TABLE \"authors\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "CREATE INDEX \"idx_posts_status\"") != null);
    // Tables come before indexes (ORDER BY (type='index'), name).
    try std.testing.expect(std.mem.indexOf(u8, dump, "CREATE TABLE").? < std.mem.indexOf(u8, dump, "CREATE INDEX").?);
    // Ledger emitted, apostrophe doubled.
    try std.testing.expect(std.mem.indexOf(u8, dump, "-- applied migrations") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "INSERT INTO \"_migrations\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "'0001_init'") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "'prov:o''brien'") != null);
    // Deterministic header, no timestamp.
    try std.testing.expect(std.mem.startsWith(u8, dump, "-- ZigBase schema dump (sqlite)\n"));
}

test "schemaDump (sqlite) skips the ledger section when _migrations is absent" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE \"posts\" (\"id\" INTEGER PRIMARY KEY, \"title\" TEXT);");
    // No `_migrations` table exists — the ledger section must be omitted, not error.
    const dump = try schemaDump(std.testing.allocator, &d, db.dbDialect(&d));
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "CREATE TABLE \"posts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "-- applied migrations") == null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "INSERT INTO \"_migrations\"") == null);
}

test "schemaDump (sqlite) is deterministic — two dumps are byte-identical" {
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE \"posts\" (\"id\" INTEGER PRIMARY KEY, \"title\" TEXT);");
    try d.exec("CREATE INDEX \"idx_posts_title\" ON \"posts\"(\"title\");");

    const a = try schemaDump(std.testing.allocator, &d, db.dbDialect(&d));
    defer std.testing.allocator.free(a);
    const b = try schemaDump(std.testing.allocator, &d, db.dbDialect(&d));
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "schemaDump (sqlite) output is re-runnable into a fresh database" {
    var src = try db.Db.openMemory();
    defer src.close();
    try src.exec("CREATE TABLE \"posts\" (\"id\" INTEGER PRIMARY KEY, \"title\" TEXT NOT NULL, \"status\" TEXT);");
    try src.exec("CREATE TABLE \"authors\" (\"id\" INTEGER PRIMARY KEY, \"name\" TEXT);");
    try src.exec("CREATE INDEX \"idx_posts_status\" ON \"posts\"(\"status\");");
    try src.exec("CREATE TABLE \"_migrations\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" TEXT UNIQUE NOT NULL, \"applied_at\" TEXT NOT NULL);");
    try src.exec("INSERT INTO \"_migrations\" (\"name\",\"applied_at\") VALUES ('0001_init','2020-01-01');");

    const dump = try schemaDump(std.testing.allocator, &src, db.dbDialect(&src));
    defer std.testing.allocator.free(dump);

    // Replay the dumped SQL into a fresh in-memory DB; it must recreate everything.
    var fresh = try db.Db.openMemory();
    defer fresh.close();
    const dump_z = try std.testing.allocator.dupeZ(u8, dump);
    defer std.testing.allocator.free(dump_z);
    try fresh.exec(dump_z);

    // Verify via sqlite_master on the fresh DB.
    var st = try fresh.prepare("SELECT \"name\" FROM \"sqlite_master\" WHERE \"type\"='table' AND \"name\" NOT LIKE 'sqlite_%' ORDER BY \"name\";");
    defer st.finalize();
    var tables: std.ArrayList([]const u8) = .empty;
    defer {
        for (tables.items) |t| std.testing.allocator.free(t);
        tables.deinit(std.testing.allocator);
    }
    while (try st.step()) try tables.append(std.testing.allocator, try std.testing.allocator.dupe(u8, st.columnText(0)));
    try std.testing.expectEqual(@as(usize, 3), tables.items.len); // authors, posts, _migrations
    // The migration ledger row round-tripped.
    var cst = try fresh.prepare("SELECT COUNT(*) FROM \"_migrations\";");
    defer cst.finalize();
    try std.testing.expect(try cst.step());
    try std.testing.expectEqual(@as(i64, 1), cst.columnInt(0));
}
