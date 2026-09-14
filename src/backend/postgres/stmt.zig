//! PostgreSQL `Stmt`, mirroring the SQLite `Stmt` surface in `src/db.zig` so call sites
//! (records/query layers) are identical across backends. Binds are 1-based (`$1..$n`);
//! column accessors are 0-based. Execution is lazy: the first `step()` runs the full
//! extended-protocol exchange (Parse/Bind/Describe/Execute/Sync) and buffers every row,
//! then `step()` walks the buffered rows. Results use TEXT format; integer/float accessors
//! parse the column's text.

const std = @import("std");
const conn_mod = @import("conn.zig");
const Conn = conn_mod.Conn;
const proto = @import("protocol.zig");
const build_options = @import("build_options");
const workbench = @import("../../query_workbench.zig");

pub const StmtError = error{ BindFailed, StepFailed, Constraint, OutOfMemory };

pub const ColumnType = enum { Null, Integer, Float, Text, Blob };

pub const Stmt = struct {
    conn: *Conn,
    gpa: std.mem.Allocator,
    sql: []const u8, // owned copy
    /// Bound TEXT param values; `null` element = SQL NULL (also the default for an
    /// unbound slot). Index `i` maps to `$#{i+1}`. Values live in `param_arena`.
    params: std.ArrayList(?[]const u8) = .empty,
    param_arena: std.heap.ArenaAllocator,
    /// Holds the buffered QueryResult (column descriptions + row bytes).
    result_arena: std.heap.ArenaAllocator,
    result: ?conn_mod.QueryResult = null,
    row_idx: usize = 0,
    cur_row: ?[]?[]const u8 = null,
    field_cipher: ?*const anyopaque = null,
    lifetime: if (build_options.query_workbench) workbench.Lifetime else void = if (build_options.query_workbench) .{} else {},

    pub fn init(conn: *Conn, gpa: std.mem.Allocator, sql: []const u8, field_cipher: ?*const anyopaque) StmtError!Stmt {
        var lifetime = if (comptime build_options.query_workbench) workbench.Lifetime.begin() else {};
        const started = if (comptime build_options.query_workbench) lifetime.started else {};
        const owned = gpa.dupe(u8, sql) catch return StmtError.OutOfMemory;
        if (comptime build_options.query_workbench) {
            lifetime.backend = .postgres;
            lifetime.afterCall(started);
            lifetime.prepared(sql);
        }
        return .{
            .conn = conn,
            .gpa = gpa,
            .sql = owned,
            .param_arena = std.heap.ArenaAllocator.init(gpa),
            .result_arena = std.heap.ArenaAllocator.init(gpa),
            .field_cipher = field_cipher,
            .lifetime = lifetime,
        };
    }

    /// PostgreSQL's Bind message encodes the parameter count as an i16, so `$1..$32767` is the
    /// hard protocol ceiling. Bounding the 1-based index here also prevents a huge index from
    /// growing the params list into an OOM / `@intCast` panic. (gemini#5.)
    const max_bind_index: c_int = 32767;

    fn ensureParam(self: *Stmt, idx: c_int) StmtError!usize {
        if (idx < 1 or idx > max_bind_index) return StmtError.BindFailed;
        const i: usize = @intCast(idx - 1);
        while (self.params.items.len <= i) {
            self.params.append(self.gpa, null) catch return StmtError.OutOfMemory;
        }
        return i;
    }

    pub fn bindText(self: *Stmt, idx: c_int, val: []const u8) StmtError!void {
        const i = try self.ensureParam(idx);
        self.params.items[i] = self.param_arena.allocator().dupe(u8, val) catch return StmtError.OutOfMemory;
    }

    pub fn bindInt(self: *Stmt, idx: c_int, val: i64) StmtError!void {
        const i = try self.ensureParam(idx);
        self.params.items[i] = std.fmt.allocPrint(self.param_arena.allocator(), "{d}", .{val}) catch return StmtError.OutOfMemory;
    }

    pub fn bindDouble(self: *Stmt, idx: c_int, val: f64) StmtError!void {
        const i = try self.ensureParam(idx);
        // Round-trippable shortest representation; PG accepts standard float text.
        self.params.items[i] = std.fmt.allocPrint(self.param_arena.allocator(), "{d}", .{val}) catch return StmtError.OutOfMemory;
    }

    pub fn bindNull(self: *Stmt, idx: c_int) StmtError!void {
        const i = try self.ensureParam(idx);
        self.params.items[i] = null;
    }

    /// Advance to the next row. The first call runs the query. Returns true if a row is
    /// available, false when exhausted (including immediately for non-SELECT statements).
    pub fn step(self: *Stmt) StmtError!bool {
        if (comptime build_options.query_workbench) self.lifetime.touch();
        if (self.result == null) {
            // One timed client exchange, not one clock read per buffered row.
            // Parameters and result materialization are part of this call.
            var measurement = if (comptime build_options.query_workbench) workbench.Measurement{ .backend = .postgres } else {};
            const started = if (comptime build_options.query_workbench) if (self.lifetime.invalidated) null else measurement.beforeKeyed(if (measurement.needsKey())
                (if (self.lifetime.scope_id != 0) self.lifetime.key else workbench.fingerprintBackend(self.sql, .postgres))
            else
                null) else {};
            var failed = if (comptime build_options.query_workbench) true else {};
            defer if (comptime build_options.query_workbench) {
                if (!self.lifetime.invalidated) {
                    const ended = measurement.after(started, false, failed);
                    self.lifetime.observeCall(started, ended);
                }
            };
            const params = self.gpa.alloc(conn_mod.Param, self.params.items.len) catch return StmtError.OutOfMemory;
            defer self.gpa.free(params);
            for (self.params.items, 0..) |v, k| params[k] = .{ .value = v };
            self.result = self.conn.execExtended(self.result_arena.allocator(), self.sql, params) catch |e| switch (e) {
                // Preserve the integrity-constraint class (→ 409) distinctly from every other
                // execution failure (→ StepFailed → 500), mirroring the SQLite backend.
                error.Constraint => return StmtError.Constraint,
                else => return StmtError.StepFailed,
            };
            self.row_idx = 0;
            if (comptime build_options.query_workbench) failed = false;
        }
        const res = self.result.?;
        if (self.row_idx >= res.rows.len) {
            self.cur_row = null;
            return false;
        }
        self.cur_row = res.rows[self.row_idx];
        self.row_idx += 1;
        return true;
    }

    fn colBytes(self: *Stmt, idx: c_int) ?[]const u8 {
        const row = self.cur_row orelse return null;
        if (idx < 0) return null;
        const i: usize = @intCast(idx);
        if (i >= row.len) return null;
        return row[i];
    }

    pub fn columnText(self: *Stmt, idx: c_int) []const u8 {
        return self.colBytes(idx) orelse "";
    }

    /// Number of result columns. Postgres only knows the row description AFTER the query
    /// has run, so this returns 0 until the first `step()` populates `self.result`; a
    /// name-mapped decoder (`data.queryAs`) steps once before reading column metadata.
    pub fn columnCount(self: *Stmt) c_int {
        const res = self.result orelse return 0;
        return @intCast(res.columns.len);
    }

    /// The result column's name (respecting any `AS` alias) at 0-based `idx`, or "" if out
    /// of range / before the first `step()`. Backed by the RowDescription copied into
    /// `result_arena`, so it stays valid until the statement is reset/finalized.
    pub fn columnName(self: *Stmt, idx: c_int) []const u8 {
        const res = self.result orelse return "";
        if (idx < 0) return "";
        const i: usize = @intCast(idx);
        if (i >= res.columns.len) return "";
        return res.columns[i].name;
    }

    /// The PG type OID of column `idx`, or null if out of range / no row description.
    fn oidOf(self: *Stmt, idx: c_int) ?u32 {
        const res = self.result orelse return null;
        if (idx < 0) return null;
        const i: usize = @intCast(idx);
        if (i >= res.columns.len) return null;
        return res.columns[i].oid;
    }

    pub fn columnInt(self: *Stmt, idx: c_int) i64 {
        const v = self.colBytes(idx) orelse return 0;
        // PostgreSQL returns booleans in TEXT format as 't'/'f', which `parseInt` cannot read
        // (→ 0, i.e. every bool reads false). `columnType` reports bool as `.Integer` to match
        // SQLite's 0/1 bool storage, so `columnInt` must decode it to 1/0. (I-5.)
        if (self.oidOf(idx) == proto.Oid.bool_) {
            return if (v.len > 0 and (v[0] == 't' or v[0] == 'T')) 1 else 0;
        }
        return std.fmt.parseInt(i64, v, 10) catch 0;
    }

    pub fn columnDouble(self: *Stmt, idx: c_int) f64 {
        const v = self.colBytes(idx) orelse return 0;
        return std.fmt.parseFloat(f64, v) catch 0;
    }

    pub fn columnType(self: *Stmt, idx: c_int) ColumnType {
        if (self.isNull(idx)) return .Null;
        const res = self.result orelse return .Text;
        if (idx < 0) return .Text;
        const i: usize = @intCast(idx);
        if (i >= res.columns.len) return .Text;
        return switch (res.columns[i].oid) {
            proto.Oid.bool_, proto.Oid.int2, proto.Oid.int4, proto.Oid.int8 => .Integer,
            proto.Oid.float4, proto.Oid.float8 => .Float,
            else => .Text, // numeric, text, timestamps, json, bytea, etc.
        };
    }

    pub fn isNull(self: *Stmt, idx: c_int) bool {
        return self.colBytes(idx) == null;
    }

    /// Re-arm the statement to be executed again (with the current or new bindings).
    /// Discards the buffered result; bindings are preserved.
    pub fn reset(self: *Stmt) void {
        const started = if (comptime build_options.query_workbench) self.lifetime.now() else {};
        self.result = null;
        self.row_idx = 0;
        self.cur_row = null;
        _ = self.result_arena.reset(.free_all);
        if (comptime build_options.query_workbench) self.lifetime.afterCall(started);
    }

    /// Forget all bindings and release their owned bytes. Unlike reset(), this
    /// does not preserve values for another execution. Batch callers should reset
    /// then clear bindings before rebinding to avoid retaining every old payload.
    pub fn clearBindings(self: *Stmt) StmtError!void {
        @memset(self.params.items, null);
        _ = self.param_arena.reset(.free_all);
    }

    pub fn finalize(self: *Stmt) void {
        const started = if (comptime build_options.query_workbench) self.lifetime.now() else {};
        self.params.deinit(self.gpa);
        self.param_arena.deinit();
        self.result_arena.deinit();
        self.gpa.free(self.sql);
        if (comptime build_options.query_workbench) self.lifetime.finish(started);
    }
};

test "clearBindings releases repeated large parameter copies without changing reset semantics" {
    var conn: Conn = undefined; // binding does not touch the connection
    var st = try Stmt.init(&conn, std.testing.allocator, "SELECT $1", null);
    defer st.finalize();
    const payload = [_]u8{'x'} ** 65536;
    for (0..128) |_| {
        try st.bindText(1, &payload);
        try std.testing.expect(st.param_arena.queryCapacity() >= payload.len);
        st.reset();
        try std.testing.expectEqualStrings(&payload, st.params.items[0].?);
        try st.clearBindings();
        try std.testing.expectEqual(@as(usize, 0), st.param_arena.queryCapacity());
        try std.testing.expectEqual(@as(?[]const u8, null), st.params.items[0]);
    }
}

test "workbench statement storage compiles away when disabled" {
    if (comptime !build_options.query_workbench) {
        try std.testing.expectEqual(void, @FieldType(Stmt, "lifetime"));
    }
}

test "pg workbench omits retained statements after scope changes but accepts unscoped prepares" {
    if (comptime !build_options.query_workbench) return error.SkipZigTest;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    var database = try @import("db.zig").Db.open(std.testing.allocator, std.testing.io, url);
    defer database.close();
    const store = try workbench.Store.create(std.testing.allocator, std.testing.io, .{});
    defer store.destroy();
    var a = workbench.Scope.init(store, "GET", "/origin");
    var b = workbench.Scope.init(store, "GET", "/other");
    var unscoped = try database.prepare("SELECT 1;");
    defer unscoped.finalize();
    var retained = blk: {
        a.enter();
        defer a.leave();
        break :blk try database.prepare("SELECT 1;");
    };
    defer retained.finalize();
    {
        b.enter();
        defer b.leave();
        try std.testing.expect(try retained.step());
        try std.testing.expectEqual(@as(usize, 0), store.count);
        try std.testing.expectEqual(@as(u64, 0), store.dropped);
        try std.testing.expect(try unscoped.step());
        try std.testing.expectEqual(@as(u64, 1), store.entries[0].executions);
    }
    {
        a.enter();
        defer a.leave();
        var st = try database.prepare("SELECT 1;");
        defer st.finalize();
        try std.testing.expect(try st.step());
        {
            b.enter();
            defer b.leave();
            st.reset();
            try std.testing.expect(try st.step());
        }
        st.reset();
        try std.testing.expect(try st.step()); // returning to origin cannot revive it
    }
    try std.testing.expectEqual(@as(usize, 2), store.count);
    try std.testing.expectEqual(@as(u64, 1), store.entries[0].executions);
    try std.testing.expectEqual(@as(u64, 1), store.entries[1].executions);
    try std.testing.expectEqual(@as(u64, 0), store.entries[1].statements);
    var outside = blk: {
        a.enter();
        defer a.leave();
        break :blk try database.prepare("SELECT 1;");
    };
    defer outside.finalize();
    try std.testing.expect(try outside.step()); // losing the scope entirely also invalidates
    {
        b.enter();
        defer b.leave();
        outside.reset();
        try std.testing.expect(try outside.step());
    }
    try std.testing.expectEqual(@as(u64, 1), store.entries[0].executions);
    var threaded = blk: {
        a.enter();
        defer a.leave();
        break :blk try database.prepare("SELECT 1;");
    };
    defer threaded.finalize();
    const H = struct {
        fn execute(st: *Stmt, target: *workbench.Store, result: *?StmtError) void {
            var scope = workbench.Scope.init(target, "GET", "/thread");
            scope.enter();
            defer scope.leave();
            _ = st.step() catch |err| {
                result.* = err;
                return;
            };
        }
    };
    var result: ?StmtError = null;
    const thread = try std.Thread.spawn(.{}, H.execute, .{ &threaded, store, &result });
    thread.join();
    try std.testing.expectEqual(null, result);
    try std.testing.expectEqual(@as(usize, 2), store.count);
    try std.testing.expectEqual(@as(u64, 0), store.dropped);
    try std.testing.expectEqual(@as(u64, 0), store.dropped_statements);
}

test "pg workbench measures buffered execution once and preserves errors and reset" {
    if (comptime !build_options.query_workbench) return error.SkipZigTest;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    var database = try @import("db.zig").Db.open(std.testing.allocator, std.testing.io, url);
    defer database.close();
    try database.exec("CREATE TEMP TABLE workbench_unique(n INTEGER UNIQUE); INSERT INTO workbench_unique VALUES (1);");
    const store = try workbench.Store.create(std.testing.allocator, std.testing.io, .{});
    defer store.destroy();
    var scope = workbench.Scope.init(store, "GET", "/pg-metrics");
    scope.enter();
    defer scope.leave();
    {
        var st = try database.prepare("SELECT n FROM generate_series(1, 100) n WHERE n > $1;");
        defer st.finalize();
        try st.bindInt(1, 0);
        try std.testing.expect(try st.step());
        const ns = store.entries[0].total_ns;
        var count: usize = 1;
        while (try st.step()) count += 1;
        try std.testing.expectEqual(@as(usize, 100), count);
        try std.testing.expectEqual(ns, store.entries[0].total_ns);
        try std.testing.expectEqual(@as(u64, 1), store.entries[0].executions);
        st.reset();
        try st.bindInt(1, 100);
        try std.testing.expect(!try st.step());
        try std.testing.expectEqual(@as(u64, 2), store.entries[0].executions);
        st.reset();
        try st.bindInt(1, 0);
        try std.testing.expect(try st.step()); // partial consumption still one exchange
    }
    try std.testing.expectEqual(@as(u64, 3), store.entries[0].executions);
    try std.testing.expectEqual(@as(u64, 1), store.entries[0].statements);
    try std.testing.expectEqual(workbench.Backend.postgres, store.entries[0].backend);
    {
        var st = try database.prepare("INSERT INTO workbench_unique VALUES ($1);");
        defer st.finalize();
        try st.bindInt(1, 1);
        try std.testing.expectError(error.Constraint, st.step());
    }
    try std.testing.expectEqual(@as(u64, 1), store.entries[1].failures);
    try std.testing.expectEqual(@as(u64, 1), store.entries[1].executions);
    {
        var st = try database.prepare("SELECT 1;");
        st.finalize(); // preparation alone must not invent an execution
    }
    try std.testing.expectEqual(@as(u64, 0), store.entries[2].executions);
    try std.testing.expectEqual(@as(u64, 1), store.entries[2].statements);
    {
        var st = try database.prepare("SELECT 1 / 0;");
        defer st.finalize();
        try std.testing.expectError(error.StepFailed, st.step());
    }
    try std.testing.expectEqual(@as(u64, 1), store.entries[3].failures);
    {
        var st = try database.prepare("SELECT 1;");
        defer st.finalize(); // buffered access elsewhere invalidates the lifetime
        try std.testing.expect(try st.step());
        {
            var nested = workbench.Scope.init(store, "GET", "/nested");
            nested.enter();
            defer nested.leave();
            try std.testing.expect(!try st.step()); // no new exchange or clock
        }
    }
    try std.testing.expectEqual(@as(u64, 1), store.entries[2].statements);
    try std.testing.expectEqual(@as(usize, 4), store.count);
}
