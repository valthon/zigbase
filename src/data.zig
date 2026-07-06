const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const records = @import("records.zig");
const migrations = @import("migrations.zig");
const auth = @import("auth.zig");
const param_sink = @import("sql/param_sink.zig");
const App = @import("app.zig").App;

/// Prepare a placeholder-bearing statement through the `$n` renumber chokepoint, so the SAME
/// SQLite-flavored SQL (`?1..?N`) prepares correctly on either backend (a no-op slice on SQLite,
/// the `$n` rewrite on Postgres). On the Postgres arm `renumberZ` allocates the rewritten SQL;
/// the DB copies the statement text at prepare time (SQLite compiles it; the PG driver puts it in
/// a Parse message), so the rewritten buffer is freed right after `prepare`. On SQLite `renumberZ`
/// returns the input slice (no allocation), so the free is guarded to the Postgres arm — this is
/// what keeps the KV paths leak-free even when called with the GPA (the `ev.writer/reader` path).
fn prep(alloc: std.mem.Allocator, conn: *db.Db, sql: [:0]const u8) !db.Stmt {
    const dialect = db.dbDialect(conn);
    const sql_p = try param_sink.renumberZ(alloc, dialect, sql);
    defer if (dialect.kind == .postgres) alloc.free(sql_p); // SQLite returns the input slice
    return conn.prepare(sql_p);
}

/// Comptime-verify every field of `Input` (an anon-struct literal's type) exists as a
/// field of `T`, so a typo'd key in a `createAs`/`updateAs` literal fails the build rather
/// than silently no-op'ing at runtime. `who` names the calling method for the error.
fn assertFieldsExist(comptime T: type, comptime Input: type, comptime who: []const u8) void {
    inline for (std.meta.fields(Input)) |f| {
        if (!@hasField(T, f.name)) {
            @compileError(who ++ ": field '" ++ f.name ++ "' is not a field of " ++ @typeName(T));
        }
    }
}

/// Connection-bound, curated record operations. Hooks, custom routes, and jobs
/// receive a `Data` rather than a raw connection. Ops run on the passed `conn`
/// and allocate their returned results on `alloc` — the caller picks the lifetime:
///
/// - `ctx.records()` binds `alloc` to the per-request/per-invocation arena, so
///   results are freed automatically when the invocation ends (no manual cleanup).
/// - The lower-level `ev.writer()`/`ev.reader()` handle accessors (WriterData /
///   ReaderData) bind `alloc` to `app.allocator` (the gpa). Results from THAT
///   path are NOT arena-freed — callers must manage their lifetimes explicitly.
///
/// ATOMICITY: `before*` record hooks run INSIDE the triggering write's transaction
/// (folded in by the A2 change). The handler opens `BEGIN IMMEDIATE` before the
/// before-hook, performs the row write + access-rule guard, and commits only on
/// success; a before-hook error (or a denied guard) rolls the WHOLE transaction
/// back — so a side-write a hook issues via `ctx.records()` commits atomically with
/// the triggering write and is discarded on abort (fail closed).
///
/// Unknown-collection contract:
///   - `findById` returns `null` for BOTH an unknown collection and a missing
///     record — an intentional collapse that mirrors the HTTP layer returning 404
///     for either case.
///   - `create`, `update`, `delete`, and `list` return `error.UnknownCollection`
///     when the collection name does not resolve.
pub const Data = struct {
    app: *App,
    conn: *db.Db,
    io: std.Io,
    /// Allocator for returned results. Caller picks the lifetime (per-invocation
    /// arena on the ctx path; app.allocator for internal/test consumers).
    alloc: std.mem.Allocator,

    pub fn findById(self: Data, col_name: []const u8, id: []const u8) !?std.json.Value {
        const col = (try collections.get(self.alloc, self.conn, col_name)) orelse return null;
        return records.get(self.alloc, self.conn, col, id);
    }
    /// Create a record. On an **auth** collection this runs the same credential transforms
    /// the HTTP layer applies — the server generates a `tokenKey` (and forces
    /// `verified=false`), hashing `password` if one is supplied — so the row works with
    /// `auth.issueSession` / `auth.mintLinkToken` immediately. `password` is OPTIONAL, so a
    /// passwordless flow (magic-link signup) provisions a credential-less but usable row. A
    /// non-auth collection takes the plain insert path. (The lower-level engine
    /// `records.create` does NOT provision — use it directly only for raw import/migration.)
    /// Errors: `error.UnknownCollection` if the name doesn't resolve; `error.NotObject` if
    /// `value` isn't a JSON object; `error.PasswordTooShort` if a supplied password is too short.
    pub fn create(self: Data, col_name: []const u8, value: std.json.Value) !std.json.Value {
        const col = (try collections.get(self.alloc, self.conn, col_name)) orelse return error.UnknownCollection;
        if (col.type != .auth) return records.create(self.alloc, self.io, self.conn, col, value);
        // Surface the same error as the non-auth path (records.create) for a non-object
        // value, rather than applyProvision's misleading PasswordTooShort.
        if (value != .object) return error.NotObject;
        const prepped = try auth.applyProvision(self.io, self.alloc, value, col.options.auth.minPasswordLength);
        // applyProvision allocates duped keys + cred strings; records.create only reads
        // `prepped` (it returns a freshly-allocated record). Free on the SAME allocator
        // (a no-op on an arena, a real free on the gpa).
        defer auth.freeProvisioned(self.alloc, prepped);
        return records.create(self.alloc, self.io, self.conn, col, prepped);
    }
    pub fn update(self: Data, col_name: []const u8, id: []const u8, value: std.json.Value) !?std.json.Value {
        const col = (try collections.get(self.alloc, self.conn, col_name)) orelse return error.UnknownCollection;
        return records.update(self.alloc, self.conn, col, id, value);
    }
    pub fn delete(self: Data, col_name: []const u8, id: []const u8) !bool {
        const col = (try collections.get(self.alloc, self.conn, col_name)) orelse return error.UnknownCollection;
        return records.delete(self.alloc, self.conn, col, id);
    }
    pub fn list(self: Data, col_name: []const u8, q: records.ListQuery) !records.ListResult {
        const col = (try collections.get(self.alloc, self.conn, col_name)) orelse return error.UnknownCollection;
        return records.list(self.alloc, self.conn, col, q);
    }

    // -----------------------------------------------------------------------
    // Typed record I/O (#238). Thin, reflective wrappers over the `std.json.Value`
    // methods above; the Value API stays for dynamic callers. The struct↔collection
    // field mapping is BY NAME: an `input`/`patch`/`T` field is matched to the
    // collection column of the same name. Optional `T` fields map to nullable/absent
    // columns; nested/optional shapes are handled by std.json. Because binding number
    // fields now accepts numeric JSON (#238 Part 1), a `T` field like `price_cents: i64`
    // stringifies to a JSON integer and binds correctly.
    //
    // The comptime guard on `createAs`/`updateAs` only verifies that every input/patch
    // field EXISTS on `T` (typo protection). It does NOT verify the field exists on the
    // COLLECTION — the collection is named at runtime, so a `T` field the collection
    // doesn't declare surfaces as the existing runtime schema-validation error.
    // -----------------------------------------------------------------------

    /// Reflect an anon-struct literal of writable fields into a `std.json.Value` object
    /// via stringify→parse. Nested/optional/number shapes are handled by std.json. Returns
    /// the `Parsed` wrapper (rather than just `.value`) so the caller can `deinit()` the
    /// backing arena the parse allocated — the `.value` itself is only a transient input
    /// to `create`/`update`, never the returned value, so it must not leak on the GPA path.
    fn valueFromStruct(self: Data, input: anytype) !std.json.Parsed(std.json.Value) {
        const bytes = try std.json.Stringify.valueAlloc(self.alloc, input, .{});
        defer self.alloc.free(bytes);
        return std.json.parseFromSlice(std.json.Value, self.alloc, bytes, .{});
    }

    /// Create a record from an anon-struct literal of the WRITABLE fields and return the
    /// full created record parsed into `T`. `input` is an anon literal, e.g.
    /// `.{ .title = "hi", .price_cents = 500, .confirmed = true }`; every field of it must
    /// exist on `T` (checked at comptime). `T` may be a subset of the record's columns —
    /// id/autodate columns `T` doesn't name are ignored on the read back.
    pub fn createAs(self: Data, comptime T: type, col_name: []const u8, input: anytype) !T {
        comptime assertFieldsExist(T, @TypeOf(input), "createAs");
        var parsed_value = try self.valueFromStruct(input);
        defer parsed_value.deinit();
        const created = try self.create(col_name, parsed_value.value);
        return try std.json.parseFromValueLeaky(T, self.alloc, created, .{ .ignore_unknown_fields = true });
    }

    /// Fetch a record by id, parsed into `T`, or `null` if the collection or record is
    /// not found. No opts arg — expand/projection is a future addition.
    pub fn getAs(self: Data, comptime T: type, col_name: []const u8, id: []const u8) !?T {
        const found = (try self.findById(col_name, id)) orelse return null;
        return try std.json.parseFromValueLeaky(T, self.alloc, found, .{ .ignore_unknown_fields = true });
    }

    /// Patch a record with an anon-struct literal of just the CHANGED fields and return the
    /// updated record parsed into `T` (or `null` if the record is missing). Every field of
    /// `patch` must exist on `T` (checked at comptime).
    pub fn updateAs(self: Data, comptime T: type, col_name: []const u8, id: []const u8, patch: anytype) !?T {
        comptime assertFieldsExist(T, @TypeOf(patch), "updateAs");
        var parsed_value = try self.valueFromStruct(patch);
        defer parsed_value.deinit();
        const updated = (try self.update(col_name, id, parsed_value.value)) orelse return null;
        return try std.json.parseFromValueLeaky(T, self.alloc, updated, .{ .ignore_unknown_fields = true });
    }

    // -----------------------------------------------------------------------
    // Key→value/settings store (#87). Small, mutable, superuser-managed values
    // over the internal `_kv` table. Values are opaque TEXT — a caller wanting
    // structured data stringifies/parses JSON itself. Feature flags (#88) are a
    // typed bool view over this same store (see `Ctx.flag`).
    // -----------------------------------------------------------------------

    /// Fetch the value for `key`, or `null` if absent. The returned slice is duped
    /// onto `self.alloc` (the caller-chosen lifetime: the per-invocation arena on
    /// the ctx path) so it outlives the finalized statement.
    pub fn kvGet(self: Data, key: []const u8) !?[]const u8 {
        var st = try prep(self.alloc, self.conn, "SELECT value FROM \"_kv\" WHERE key = ?1;");
        defer st.finalize();
        try st.bindText(1, key);
        if (!(try st.step())) return null;
        return try self.alloc.dupe(u8, st.columnText(0));
    }

    /// Upsert `key`→`value`. Preserves the original `created` timestamp across updates
    /// and bumps `updated`.
    pub fn kvSet(self: Data, key: []const u8, value: []const u8) !void {
        // `_kv.created`/`updated` are TEXT ISO timestamps → `nowTextExpr` (byte-identical
        // `datetime('now')` on SQLite, the ISO `to_char` form on Postgres). The upsert's
        // `ON CONFLICT(key)` target is the `_kv` PRIMARY KEY (migration 0009), valid on both
        // backends; `excluded` is the standard conflict-row alias on SQLite and Postgres.
        const dialect = db.dbDialect(self.conn);
        const now = dialect.nowTextExpr();
        const sql = try std.fmt.allocPrintSentinel(self.alloc,
            \\INSERT INTO "_kv"(key,value,created,updated)
            \\VALUES(?1,?2,{s},{s})
            \\ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated={s};
        , .{ now, now, now }, 0);
        defer self.alloc.free(sql);
        const sql_p = try param_sink.renumberZ(self.alloc, dialect, sql);
        defer if (dialect.kind == .postgres) self.alloc.free(sql_p); // SQLite returns the input slice
        var st = try self.conn.prepare(sql_p);
        defer st.finalize();
        try st.bindText(1, key);
        try st.bindText(2, value);
        _ = try st.step();
    }

    /// Delete `key`. Returns whether a row existed.
    pub fn kvDelete(self: Data, key: []const u8) !bool {
        var st = try prep(self.alloc, self.conn, "DELETE FROM \"_kv\" WHERE key = ?1;");
        defer st.finalize();
        try st.bindText(1, key);
        _ = try st.step();
        return self.conn.changesCount() > 0;
    }

    /// One entry in the KV/settings store.
    pub const KvEntry = struct { key: []const u8, value: []const u8, created: []const u8, updated: []const u8 };

    /// List all KV/settings entries (ordered by key). Each field is duped onto
    /// `self.alloc`. Intended for the superuser settings admin surface.
    pub fn kvList(self: Data) ![]KvEntry {
        var out: std.ArrayList(KvEntry) = .empty;
        var st = try self.conn.prepare("SELECT key, value, created, updated FROM \"_kv\" ORDER BY key;");
        defer st.finalize();
        while (try st.step()) {
            try out.append(self.alloc, .{
                .key = try self.alloc.dupe(u8, st.columnText(0)),
                .value = try self.alloc.dupe(u8, st.columnText(1)),
                .created = try self.alloc.dupe(u8, st.columnText(2)),
                .updated = try self.alloc.dupe(u8, st.columnText(3)),
            });
        }
        return out.toOwnedSlice(self.alloc);
    }

    /// Scan `_kv` for every entry whose key prefix-matches one of `prefixes` (each
    /// matched as `<prefix><wildcard>`), in a single parameter-bound query. Used by the
    /// feature-flag resolver to batch the `flag:*` / `exp:*` reads. Each field is
    /// duped onto `self.alloc`; results are ordered by key.
    ///
    /// The prefix-match operator is dialect-selected (`GLOB '<p>*'` on SQLite — case-sensitive;
    /// `LIKE '<p>%'` on Postgres — also case-sensitive). SQLite's `LIKE` is case-INSENSITIVE, so
    /// the two backends must use different operators to keep identical semantics; the prefixes are
    /// internal constants without wildcard metacharacters, so no pattern escaping is needed.
    pub fn kvScanPrefix(self: Data, prefixes: []const []const u8) ![]KvEntry {
        if (prefixes.len == 0) return &.{};
        const dialect = db.dbDialect(self.conn);
        const op = dialect.prefixMatchOp();
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(self.alloc);
        try sql.appendSlice(self.alloc, "SELECT key, value, created, updated FROM \"_kv\" WHERE ");
        for (prefixes, 0..) |_, i| {
            if (i > 0) try sql.appendSlice(self.alloc, " OR ");
            const clause = try std.fmt.allocPrint(self.alloc, "key {s} ?{d}", .{ op, i + 1 });
            defer self.alloc.free(clause); // copied by appendSlice; only a build-time temporary
            try sql.appendSlice(self.alloc, clause);
        }
        try sql.appendSlice(self.alloc, " ORDER BY key;");
        const sql_z = try self.alloc.dupeZ(u8, sql.items);
        defer self.alloc.free(sql_z);

        // Route the assembled, placeholder-bearing SQL through the `$n` renumber chokepoint
        // (`?N`→`$N` on Postgres, unchanged on SQLite). The DB copies the SQL text at prepare
        // time, so both buffers are build-time temporaries.
        const sql_p = try param_sink.renumberZ(self.alloc, dialect, sql_z);
        defer if (dialect.kind == .postgres) self.alloc.free(sql_p); // SQLite returns sql_z (freed above)

        var st = try self.conn.prepare(sql_p);
        defer st.finalize();
        const wild = dialect.prefixWildcard();
        for (prefixes, 0..) |p, i| {
            const pat = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ p, wild });
            defer self.alloc.free(pat); // bind copies the bytes at bind time
            try st.bindText(@intCast(i + 1), pat);
        }

        var out: std.ArrayList(KvEntry) = .empty;
        while (try st.step()) {
            try out.append(self.alloc, .{
                .key = try self.alloc.dupe(u8, st.columnText(0)),
                .value = try self.alloc.dupe(u8, st.columnText(1)),
                .created = try self.alloc.dupe(u8, st.columnText(2)),
                .updated = try self.alloc.dupe(u8, st.columnText(3)),
            });
        }
        return out.toOwnedSlice(self.alloc);
    }
};

test "Data kvSet/kvGet/kvDelete round-trip; upsert preserves created" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var app = App{ .allocator = a, .io = io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = io, .alloc = a };

    // Missing key -> null.
    try std.testing.expect((try d.kvGet("missing")) == null);

    // Set then get round-trips.
    try d.kvSet("greeting", "hello");
    try std.testing.expectEqualStrings("hello", (try d.kvGet("greeting")).?);

    // Capture created, then update and assert value changed but created preserved.
    var st = try conn.prepare("SELECT created, updated FROM \"_kv\" WHERE key='greeting';");
    try std.testing.expect((try st.step()));
    const created0 = try a.dupe(u8, st.columnText(0));
    st.finalize();

    try d.kvSet("greeting", "world");
    try std.testing.expectEqualStrings("world", (try d.kvGet("greeting")).?);
    var st2 = try conn.prepare("SELECT created FROM \"_kv\" WHERE key='greeting';");
    defer st2.finalize();
    try std.testing.expect((try st2.step()));
    try std.testing.expectEqualStrings(created0, st2.columnText(0)); // created unchanged

    // Delete reports existence, then absence.
    try std.testing.expect(try d.kvDelete("greeting"));
    try std.testing.expect((try d.kvGet("greeting")) == null);
    try std.testing.expect(!(try d.kvDelete("greeting")));
}

test "Data.kvList returns all entries ordered by key" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App{ .allocator = a, .io = std.testing.io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = std.testing.io, .alloc = a };

    try std.testing.expectEqual(@as(usize, 0), (try d.kvList()).len);
    try d.kvSet("b", "2");
    try d.kvSet("a", "1");
    const list = try d.kvList();
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("a", list[0].key);
    try std.testing.expectEqualStrings("1", list[0].value);
    try std.testing.expectEqualStrings("b", list[1].key);
}

test "Data.kvScanPrefix returns only prefix-matching entries across multiple prefixes" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App{ .allocator = a, .io = std.testing.io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = std.testing.io, .alloc = a };

    try d.kvSet("flag:beta", "true");
    try d.kvSet("exp:layout:weights", "[90,10]");
    try d.kvSet("welcome_banner", "hi"); // unrelated key — must NOT match

    const hits = try d.kvScanPrefix(&.{ "flag:", "exp:" });
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    // Ordered by key: "exp:..." sorts before "flag:...".
    try std.testing.expectEqualStrings("exp:layout:weights", hits[0].key);
    try std.testing.expectEqualStrings("flag:beta", hits[1].key);
    try std.testing.expectEqualStrings("true", hits[1].value);

    // Empty prefix list → no rows.
    try std.testing.expectEqual(@as(usize, 0), (try d.kvScanPrefix(&.{})).len);
}

test "Data.create then findById round-trips a record" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try migrations.run(&conn);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } },
    };
    _ = try collections.create(a, io, &conn, .{ .id = "", .name = "posts", .fields = &fields });

    var app = App{ .allocator = a, .io = io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = io, .alloc = a };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "title", .{ .string = "hello" });
    const created = try d.create("posts", .{ .object = obj });
    const id = created.object.get("id").?.string;

    const found = (try d.findById("posts", id)).?;
    try std.testing.expectEqualStrings("hello", found.object.get("title").?.string);
}

test "Data typed I/O: createAs/getAs/updateAs round-trip through T" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try migrations.run(&conn);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "qty", .options = .{ .number = .{ .mode = .int } } },
        .{ .id = "f3", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
        .{ .id = "f4", .name = "confirmed", .options = .{ .bool = .{} } },
        .{ .id = "f5", .name = "note", .options = .{ .text = .{} } },
    };
    _ = try collections.create(a, io, &conn, .{ .id = "", .name = "widgets", .fields = &fields });

    var app = App{ .allocator = a, .io = io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = io, .alloc = a };

    // `.int`-mode fields map to a Zig integer (parseFromValue parses the numeric string
    // back into `i64`); `.fixed`-mode fields read back as DECIMAL STRINGS (values.zig
    // contract) and so must stay `[]const u8` in `T`. An optional field maps to a
    // nullable/absent column.
    const Widget = struct {
        id: []const u8,
        title: []const u8,
        qty: i64,
        price: []const u8,
        confirmed: bool,
        note: ?[]const u8,
    };

    // createAs: a numeric field is passed AS A NUMBER (proves Part 1 + Part 2 compose);
    // `note` is omitted (optional → null).
    const created = try d.createAs(Widget, "widgets", .{
        .title = "hello",
        .qty = 7,
        .price = 5.0,
        .confirmed = true,
    });
    try std.testing.expectEqualStrings("hello", created.title);
    try std.testing.expectEqual(@as(i64, 7), created.qty);
    try std.testing.expectEqualStrings("5.00", created.price); // 5.0 scaled to fixed(2)
    try std.testing.expectEqual(true, created.confirmed);
    try std.testing.expect(created.note == null);

    // getAs: fetch the same record as Widget.
    const got = (try d.getAs(Widget, "widgets", created.id)).?;
    try std.testing.expectEqualStrings("hello", got.title);
    try std.testing.expectEqual(@as(i64, 7), got.qty);
    try std.testing.expectEqualStrings("5.00", got.price);
    try std.testing.expect(got.note == null);

    // getAs on a missing id → null.
    try std.testing.expect((try d.getAs(Widget, "widgets", "nonexistent")) == null);

    // updateAs: change one field; the rest stay intact; the optional round-trips a value.
    const updated = (try d.updateAs(Widget, "widgets", created.id, .{ .qty = 99, .note = "restocked" })).?;
    try std.testing.expectEqual(@as(i64, 99), updated.qty);
    try std.testing.expectEqualStrings("hello", updated.title); // untouched
    try std.testing.expectEqualStrings("5.00", updated.price); // untouched
    try std.testing.expectEqual(true, updated.confirmed); // untouched
    try std.testing.expectEqualStrings("restocked", updated.note.?);

    // updateAs on a missing id → null.
    try std.testing.expect((try d.updateAs(Widget, "widgets", "nonexistent", .{ .qty = 1 })) == null);
}

test "Data typed I/O on the raw GPA path: valueFromStruct and parseFromValueLeaky do not leak" {
    // `ev.writer()`/`ev.reader()` bind `Data.alloc` to `app.allocator` (a real GPA), NOT an
    // arena — so the intermediate `bytes`/`Parsed(Value)` temporaries in `valueFromStruct`
    // and the `parseFromValue` wrapper `createAs`/`getAs`/`updateAs` used to return (rather
    // than `parseFromValueLeaky`) are real, permanent leaks on that path; an arena masks
    // them by reclaiming everything at once. `std.testing.allocator` fails the test on any
    // unfreed byte, so it catches exactly this class of bug. (Schema/collection setup below
    // stays on a throwaway arena — GPA leak-checking that is orthogonal to this PR's fix.)
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try migrations.run(&conn);

    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    const sa = setup_arena.allocator();
    const io = std.testing.io;

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
    };
    _ = try collections.create(sa, io, &conn, .{ .id = "", .name = "gadgets", .fields = &fields });

    // `valueFromStruct` on its own, GPA-backed: must not leak the intermediate `bytes` (the
    // fix adds `defer self.alloc.free(bytes)`), and returns a `Parsed(Value)` the caller
    // deinits (rather than the old bare `.value`, which discarded — and leaked — the parse
    // tree's backing arena).
    var app = App{ .allocator = std.testing.allocator, .io = io, .pool = undefined };
    const gpa_data = Data{ .app = &app, .conn = &conn, .io = io, .alloc = std.testing.allocator };
    {
        var parsed = try gpa_data.valueFromStruct(.{ .title = "hi", .price = 5.0 });
        defer parsed.deinit();
        try std.testing.expectEqualStrings("hi", parsed.value.object.get("title").?.string);
    }

    // The `parseFromValueLeaky` swap in `createAs`/`getAs`/`updateAs`: parse a manually-built
    // `std.json.Value` (on a throwaway arena — irrelevant to what's under test) into `T` on
    // the GPA, then free exactly the fields `T` owns. Before the fix this used
    // `parseFromValue` and threw away (leaked) the `Parsed(T)` wrapper's arena on every call.
    const Gadget = struct { title: []const u8, price: []const u8, note: ?[]const u8 };
    var src_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer src_arena.deinit();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(src_arena.allocator(), "title", .{ .string = "hi" });
    try obj.put(src_arena.allocator(), "price", .{ .string = "5.00" });
    try obj.put(src_arena.allocator(), "note", .null);
    const g = try std.json.parseFromValueLeaky(Gadget, std.testing.allocator, .{ .object = obj }, .{ .ignore_unknown_fields = true });
    defer {
        std.testing.allocator.free(g.title);
        std.testing.allocator.free(g.price);
    }
    try std.testing.expectEqualStrings("hi", g.title);
    try std.testing.expectEqualStrings("5.00", g.price);
    try std.testing.expect(g.note == null);
}

// compile-error: `d.createAs(Widget, "widgets", .{ .titel = "x" })` (typo) fails the build
// with "createAs: field 'titel' is not a field of ...Widget" via assertFieldsExist. This
// cannot be an executable test (a @compileError would fail the whole build), so it is a note.

test "Data.create on an unknown collection errors; findById collapses to null" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try migrations.run(&conn);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var app = App{ .allocator = a, .io = io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = io, .alloc = a };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "title", .{ .string = "hello" });
    try std.testing.expectError(error.UnknownCollection, d.create("nope", .{ .object = obj }));

    // findById intentionally collapses unknown-collection and missing-record to null.
    try std.testing.expect((try d.findById("nope", "x")) == null);
}
