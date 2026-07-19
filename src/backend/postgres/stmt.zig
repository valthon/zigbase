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

    pub fn init(conn: *Conn, gpa: std.mem.Allocator, sql: []const u8, field_cipher: ?*const anyopaque) StmtError!Stmt {
        const owned = gpa.dupe(u8, sql) catch return StmtError.OutOfMemory;
        return .{
            .conn = conn,
            .gpa = gpa,
            .sql = owned,
            .param_arena = std.heap.ArenaAllocator.init(gpa),
            .result_arena = std.heap.ArenaAllocator.init(gpa),
            .field_cipher = field_cipher,
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
        if (self.result == null) {
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
        self.result = null;
        self.row_idx = 0;
        self.cur_row = null;
        _ = self.result_arena.reset(.free_all);
    }

    pub fn finalize(self: *Stmt) void {
        self.params.deinit(self.gpa);
        self.param_arena.deinit();
        self.result_arena.deinit();
        self.gpa.free(self.sql);
    }
};
