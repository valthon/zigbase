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

// ===========================================================================
// queryAs — name-mapped raw-SQL row decoding (#240)
// ===========================================================================
//
// Complex reads (joins, aggregates, window scans) drop below the collection API to
// raw SQL, where the row layer is POSITIONAL — `st.columnText(28)` — which silently
// corrupts the moment a column is inserted into the SELECT. `queryAs` decodes each
// result row into a struct `T` by matching every field to the result column of the
// SAME NAME (via the statement's column name, respecting `AS` aliases), not by
// position, so reordering / inserting SELECT columns can never misalign a field.
//
//   const rows = try data.queryAs(OrderRow, conn, arena,
//       "SELECT o.*, c.\"email\" AS customer_email FROM \"orders\" o " ++
//       "JOIN \"customers\" c ON c.id = o.customer_id WHERE o.total > ?1",
//       .{ min_total });   // []OrderRow, strings owned by `arena`
//
// - Get a `conn` (`*db.Db`) from `ctx.connForRead()` (a pooled reader) in a hook/route/job,
//   or `ctx.app.pool.acquireWriter()` for a raw write. `ctx.records().queryAs(T, sql, args)`
//   is the ergonomic wrapper (reader + invocation arena supplied for you).
// - Args bind POSITIONALLY: tuple element `i` → placeholder `?{i+1}` (`$` on Postgres via
//   the same `$n` renumber chokepoint used everywhere). Supported arg types: `[]const u8`
//   (incl. string literals), integers, floats, `bool`, `?T` (payload or NULL), and `null`.
// - Field decoding is by Zig type: `[]const u8` (duped onto `alloc`), any integer, any float,
//   `bool`, and `?T` over a nullable column (SQL NULL → `null`, else the payload).
// - A NON-optional `T` field with NO matching result column is a hard error
//   (`error.ColumnNotFound`, the field named in a log line — Zig errors can't carry text).
//   An OPTIONAL field with no matching column decodes to `null` (absent ⇒ null).
// - A SQL NULL landing in a NON-optional field is COERCED to the type's zero value
//   (`""` / `0` / `0.0` / `false`), matching the raw column accessors' NULL behavior — make
//   the field `?T` if you need to distinguish NULL. Wrap it optional to observe NULL.
// - EXTRA result columns not present in `T` are ignored (the common `SELECT o.*, …` case).
//   A strict "error on unmapped column" mode is a possible future addition; there is no opts
//   arg in v1.

/// Bind one positional arg `val` at 1-based `idx`, dispatched on its Zig type. Unsupported
/// types are a `@compileError` (the type is comptime-known, so the switch is a comptime switch
/// and only the taken prong is analyzed).
fn bindArg(st: *db.Stmt, idx: c_int, val: anytype) !void {
    const VT = @TypeOf(val);
    switch (@typeInfo(VT)) {
        // `std.math.cast` returns null (never panics) when the value doesn't fit i64 — the real
        // edge is a `u64`/`usize`/`u128` id above i64 max. Fail loudly instead of a panic; the
        // value is logged at `.warn` (the ColumnNotFound precedent — a Zig error can't carry it).
        .int, .comptime_int => {
            const v64 = std.math.cast(i64, val) orelse {
                std.log.warn("queryAs: integer arg {d} at ?{d} exceeds the i64 bind range", .{ val, idx });
                return error.IntegerArgTooLarge;
            };
            try st.bindInt(idx, v64);
        },
        .float, .comptime_float => try st.bindDouble(idx, @floatCast(val)),
        .bool => try st.bindInt(idx, if (val) 1 else 0),
        .null => try st.bindNull(idx),
        .optional => {
            if (val) |v| try bindArg(st, idx, v) else try st.bindNull(idx);
        },
        .pointer => |p| switch (p.size) {
            // []const u8 slice.
            .slice => if (p.child == u8) {
                try st.bindText(idx, val);
            } else @compileError("queryAs: unsupported arg type " ++ @typeName(VT)),
            // *const [N:0]u8 — a string literal; coerces to []const u8 for bindText.
            .one => {
                const ci = @typeInfo(p.child);
                if (ci == .array and ci.array.child == u8) {
                    try st.bindText(idx, val);
                } else @compileError("queryAs: unsupported arg type " ++ @typeName(VT));
            },
            else => @compileError("queryAs: unsupported arg type " ++ @typeName(VT)),
        },
        else => @compileError("queryAs: unsupported arg type " ++ @typeName(VT)),
    }
}

/// Decode a scalar (non-optional) field of type `FT` from result column `idx`. A SQL NULL is
/// coerced to the type's zero value (via the raw accessors: text→"", int→0, double→0.0).
fn decodeScalar(comptime FT: type, st: *db.Stmt, idx: c_int, alloc: std.mem.Allocator) !FT {
    switch (@typeInfo(FT)) {
        // `FT` can be any integer width/signedness (u8/i32/usize/…), while `columnInt` returns
        // i64 from external DB data — a plain `@intCast` PANICS in Safe builds if the value is
        // out of `FT`'s range (or negative into an unsigned FT). `std.math.cast` makes that a
        // loud error instead (value logged at `.warn`, the ColumnNotFound/IntegerArgTooLarge
        // precedent so the expectError test doesn't trip the runner's `.err` gate). `FT == i64`
        // always succeeds — no regression for i64 fields.
        .int => {
            const val = st.columnInt(idx);
            return std.math.cast(FT, val) orelse {
                std.log.warn("queryAs: column value {d} does not fit field type {s}", .{ val, @typeName(FT) });
                return error.IntegerOverflow;
            };
        },
        .float => return @floatCast(st.columnDouble(idx)),
        .bool => return st.columnInt(idx) != 0,
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return try alloc.dupe(u8, st.columnText(idx));
            @compileError("queryAs: unsupported field type " ++ @typeName(FT));
        },
        else => @compileError("queryAs: unsupported field type " ++ @typeName(FT)),
    }
}

/// Decode field `FT` from resolved column `idx` (`idx < 0` = no matching column, only ever
/// passed for an optional field → `null`). Optionals decode NULL/absent to `null`.
fn decodeField(comptime FT: type, st: *db.Stmt, idx: c_int, alloc: std.mem.Allocator) !FT {
    switch (@typeInfo(FT)) {
        .optional => |o| {
            if (idx < 0) return null; // field has no matching result column
            if (st.isNull(idx)) return null;
            return try decodeScalar(o.child, st, idx, alloc);
        },
        else => return try decodeScalar(FT, st, idx, alloc),
    }
}

/// Run `sql` (with positionally-bound `args`) and decode every result row into a `T`, mapping
/// struct fields to result columns BY NAME. Returns `[]T` allocated on `alloc`; each `[]const u8`
/// field is duped onto `alloc`, so on the ctx path (arena) they live as long as the invocation.
///
/// Errors: `error.ColumnNotFound` if a non-optional `T` field has no matching result column
/// (the field is named in a log line); plus any DB error from prepare/bind/step. See the
/// module-level comment above for the full type-mapping and NULL contract.
pub fn queryAs(comptime T: type, conn: *db.Db, alloc: std.mem.Allocator, sql: [:0]const u8, args: anytype) ![]T {
    if (@typeInfo(T) != .@"struct") @compileError("queryAs: T must be a struct, got " ++ @typeName(T));

    var st = try prep(alloc, conn, sql);
    defer st.finalize();

    // Bind args positionally (SQLite/PG placeholder binds are 1-based).
    inline for (std.meta.fields(@TypeOf(args)), 0..) |f, i| {
        try bindArg(&st, @intCast(i + 1), @field(args, f.name));
    }

    // Force execution + expose column metadata. SQLite knows the column names right after
    // prepare; Postgres only after the row description arrives with the first step(). Stepping
    // once here populates the column map on BOTH backends (and gives us the first row, if any).
    var has_row = try st.step();

    // Resolve each field of T to a result-column index BY NAME, once. A non-optional field
    // with no matching column is a hard error (named in the log); an optional one resolves
    // to -1 and decodes to null.
    const fields = std.meta.fields(T);
    var col_of: [fields.len]c_int = undefined;
    const ncols = st.columnCount();
    inline for (fields, 0..) |f, fi| {
        var found: c_int = -1;
        var ci: c_int = 0;
        while (ci < ncols) : (ci += 1) {
            if (std.mem.eql(u8, st.columnName(ci), f.name)) {
                found = ci;
                break;
            }
        }
        if (found < 0 and @typeInfo(f.type) != .optional) {
            // Named here because a Zig error value can't carry the field name. Logged at
            // `.warn`, not `.err`: unit tests exercise this via `expectError` and an
            // `.err`-level log trips the Zig test runner's "logged N errors" gate (same
            // precedent as `migrator.notReversible` / `provision.injectOAuthSecrets`). The
            // returned error still surfaces loudly to the caller.
            std.log.warn("queryAs: no result column named '{s}' for non-optional field {s}.{s}", .{ f.name, @typeName(T), f.name });
            return error.ColumnNotFound;
        }
        col_of[fi] = found;
    }

    var list: std.ArrayList(T) = .empty;
    errdefer list.deinit(alloc);
    while (has_row) {
        var row: T = undefined;
        inline for (fields, 0..) |f, fi| {
            @field(row, f.name) = try decodeField(f.type, &st, col_of[fi], alloc);
        }
        try list.append(alloc, row);
        has_row = try st.step();
    }
    return list.toOwnedSlice(alloc);
}

/// Connection-bound, curated record operations. Hooks, custom routes, and jobs
/// receive a `Data` rather than a raw connection. Ops run on the passed `conn`
/// and allocate their returned results on `alloc` — the caller picks the lifetime:
///
/// - `ctx.records()` binds `alloc` to the per-request/per-invocation arena, so
///   results are freed automatically when the invocation ends (no manual cleanup).
/// - The lower-level `ev.writer()`/`ev.reader()` handle accessors (WriterData /
///   ReaderData) bind `alloc` to an arena OWNED BY THE HANDLE (see events.zig),
///   so results — and all internal scratch (collection metadata, SQL buffers) —
///   are freed together when the handle's `deinit()` runs. Results are valid until
///   `deinit()`; a caller that must outlive the handle copies them first.
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

test "Data record methods round-trip create/findById/update/list/delete" {
    // Functional coverage on an arena for all five record methods (the leak-clean GPA-path
    // regression for these lives in events.zig, driven through a WriterData handle).
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
    };
    _ = try collections.create(a, io, &conn, .{ .id = "", .name = "posts", .fields = &fields });

    var app = App{ .allocator = a, .io = io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = io, .alloc = a };

    var input: std.json.ObjectMap = .empty;
    try input.put(a, "title", .{ .string = "hello" });
    try input.put(a, "qty", .{ .integer = 7 });
    const created = try d.create("posts", .{ .object = input });
    try std.testing.expectEqualStrings("hello", created.object.get("title").?.string);
    const id = created.object.get("id").?.string;

    const found = (try d.findById("posts", id)).?;
    try std.testing.expectEqualStrings("hello", found.object.get("title").?.string);

    var patch: std.json.ObjectMap = .empty;
    try patch.put(a, "qty", .{ .integer = 99 });
    const updated = (try d.update("posts", id, .{ .object = patch })).?;
    try std.testing.expectEqualStrings("99", updated.object.get("qty").?.string); // int mode → string
    try std.testing.expectEqualStrings("hello", updated.object.get("title").?.string); // untouched

    const res = try d.list("posts", .{});
    try std.testing.expectEqual(@as(usize, 1), res.items.len);
    try std.testing.expectEqualStrings("hello", res.items[0].object.get("title").?.string);

    try std.testing.expect(try d.delete("posts", id));
    try std.testing.expect((try d.findById("posts", id)) == null);
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

// --- queryAs (#240) --------------------------------------------------------

test "queryAs maps result columns to struct fields BY NAME, not position" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, total REAL, note TEXT, paid INTEGER);");
    try conn.exec(
        \\INSERT INTO orders (id, total, note, paid) VALUES
        \\ (1, 10.5, 'first', 1), (2, 99.0, 'second', 0), (3, 4.0, 'third', 1);
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Field order is DELIBERATELY unlike the SELECT column order, and `label` maps to an
    // `AS`-aliased column — so a correct result proves name-mapping, not position. `descr`
    // is an extra SELECT column NOT in the struct (must be ignored). The `WHERE total > ?1`
    // proves positional float-arg binding.
    const Row = struct {
        paid: bool,
        label: []const u8,
        total: f64,
        id: i64,
    };
    const rows = try queryAs(Row, &conn, a, "SELECT id, total, note AS label, paid, note AS descr FROM orders WHERE total > ?1 ORDER BY id;", .{@as(f64, 6.0)});

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].id);
    try std.testing.expectEqualStrings("first", rows[0].label);
    try std.testing.expectEqual(@as(f64, 10.5), rows[0].total);
    try std.testing.expectEqual(true, rows[0].paid);
    try std.testing.expectEqual(@as(i64, 2), rows[1].id);
    try std.testing.expectEqualStrings("second", rows[1].label);
    try std.testing.expectEqual(false, rows[1].paid); // paid=0 → bool false
}

test "queryAs optional field: NULL → null, present → value" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, note TEXT);");
    try conn.exec("INSERT INTO t (id, note) VALUES (1, 'has'), (2, NULL);");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Row = struct { id: i64, note: ?[]const u8 };
    const rows = try queryAs(Row, &conn, a, "SELECT id, note FROM t ORDER BY id;", .{});
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("has", rows[0].note.?);
    try std.testing.expect(rows[1].note == null);
}

test "queryAs optional field with NO matching column decodes to null" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE t (id INTEGER PRIMARY KEY);");
    try conn.exec("INSERT INTO t (id) VALUES (7);");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `missing` has no column in the SELECT; being optional, it resolves to null (not an error).
    const Row = struct { id: i64, missing: ?[]const u8 };
    const rows = try queryAs(Row, &conn, a, "SELECT id FROM t;", .{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 7), rows[0].id);
    try std.testing.expect(rows[0].missing == null);
}

test "queryAs: a non-optional field with no matching column errors (even with zero rows)" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);");
    // No rows inserted — the missing-column check still fires off the column description.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Row = struct { id: i64, absent: []const u8 };
    try std.testing.expectError(error.ColumnNotFound, queryAs(Row, &conn, a, "SELECT id, name FROM t;", .{}));
}

test "queryAs binds positional args of each supported type (text/int/float/bool)" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER, price REAL, active INTEGER);");
    try conn.exec(
        \\INSERT INTO t (id, name, qty, price, active) VALUES
        \\ (1, 'keep', 5, 2.50, 1), (2, 'skip', 5, 2.50, 1), (3, 'keep', 9, 9.99, 0);
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Row = struct { id: i64, name: []const u8 };
    // text ?1, int ?2, float ?3, bool ?4 — all four bound positionally in one query.
    const rows = try queryAs(Row, &conn, a, "SELECT id, name FROM t WHERE name = ?1 AND qty = ?2 AND price = ?3 AND active = ?4;", .{ @as([]const u8, "keep"), @as(i64, 5), @as(f64, 2.50), true });
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].id);
    try std.testing.expectEqualStrings("keep", rows[0].name);
}

test "queryAs: string-literal and optional args bind correctly" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);");
    try conn.exec("INSERT INTO t (id, name) VALUES (1, 'ada'), (2, 'grace');");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Row = struct { id: i64, name: []const u8 };
    // A bare string literal (`*const [3:0]u8`) coerces to bound TEXT.
    const rows = try queryAs(Row, &conn, a, "SELECT id, name FROM t WHERE name = ?1;", .{"ada"});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("ada", rows[0].name);

    // An optional arg: Some binds the payload…
    const some: ?i64 = 2;
    const r2 = try queryAs(Row, &conn, a, "SELECT id, name FROM t WHERE id = ?1;", .{some});
    try std.testing.expectEqual(@as(usize, 1), r2.len);
    try std.testing.expectEqualStrings("grace", r2[0].name);

    // …and null binds SQL NULL (matches no row here).
    const none: ?i64 = null;
    const r3 = try queryAs(Row, &conn, a, "SELECT id, name FROM t WHERE id = ?1;", .{none});
    try std.testing.expectEqual(@as(usize, 0), r3.len);
}

test "queryAs: a JOIN with an aliased column across tables decodes by name" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE customers (id INTEGER PRIMARY KEY, email TEXT);");
    try conn.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total REAL);");
    try conn.exec("INSERT INTO customers (id, email) VALUES (10, 'a@x.io');");
    try conn.exec("INSERT INTO orders (id, customer_id, total) VALUES (1, 10, 42.0);");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const OrderRow = struct { id: i64, total: f64, customer_email: []const u8 };
    const rows = try queryAs(OrderRow, &conn, a,
        \\SELECT o.id, o.total, c.email AS customer_email
        \\FROM orders o JOIN customers c ON c.id = o.customer_id;
    , .{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].id);
    try std.testing.expectEqual(@as(f64, 42.0), rows[0].total);
    try std.testing.expectEqualStrings("a@x.io", rows[0].customer_email);
}

test "queryAs: a u64 arg above i64 max errors instead of panicking" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE t (id INTEGER PRIMARY KEY);");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Row = struct { id: i64 };
    // A u64 beyond i64 max would `@intCast`-panic; `std.math.cast` makes it a loud error.
    const too_big: u64 = @as(u64, std.math.maxInt(i64)) + 1;
    try std.testing.expectError(error.IntegerArgTooLarge, queryAs(Row, &conn, a, "SELECT id FROM t WHERE id = ?1;", .{too_big}));

    // A u64 that DOES fit i64 binds fine (proves the cast, not a blanket reject).
    const fits: u64 = 7;
    _ = try queryAs(Row, &conn, a, "SELECT id FROM t WHERE id = ?1;", .{fits});
}

test "queryAs: a column value that overflows a narrow/unsigned field errors instead of panicking" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER, small INTEGER);");
    // n=300 overflows a u8; small=-5 is negative into an unsigned field.
    try conn.exec("INSERT INTO t (id, n, small) VALUES (1, 300, -5), (2, 42, 7);");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Reading 300 into a u8 field would `@intCast`-panic in a Safe build; the checked cast
    // makes it a loud, recoverable error.
    const Narrow = struct { id: i64, n: u8 };
    try std.testing.expectError(error.IntegerOverflow, queryAs(Narrow, &conn, a, "SELECT id, n FROM t WHERE id = ?1;", .{@as(i64, 1)}));

    // A negative value into an unsigned field also errors, not panics.
    const Unsigned = struct { id: i64, small: u32 };
    try std.testing.expectError(error.IntegerOverflow, queryAs(Unsigned, &conn, a, "SELECT id, small FROM t WHERE id = ?1;", .{@as(i64, 1)}));

    // A value that FITS the narrow field decodes correctly (proves it's a real cast, not a reject).
    const rows = try queryAs(Narrow, &conn, a, "SELECT id, n FROM t WHERE id = ?1;", .{@as(i64, 2)});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(u8, 42), rows[0].n);
}
