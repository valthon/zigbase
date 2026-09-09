//! Operator-only diagnostics. No arbitrary SQL or parameter values are accepted.
const std = @import("std");
const http = @import("../http.zig");
const auth = @import("../auth.zig");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const ddl = @import("../ddl.zig");
const workbench = @import("../query_workbench.zig");
const ApiError = @import("error.zig").ApiError;

fn authorize(ctx: *http.RequestCtx) !?http.Response {
    if (ctx.bearerToken() == null) return try ApiError.unauthorized().toResponse(ctx.allocator.a);
    const app = ctx.app.?;
    var reader = try app.pool.acquireReader();
    defer app.pool.releaseReader(&reader);
    const who = (try auth.authenticate(app.io, ctx.allocator.a, app, ctx, &reader)) orelse return try ApiError.unauthorized().toResponse(ctx.allocator.a);
    if (!who.is_superuser) return try ApiError.forbidden().toResponse(ctx.allocator.a);
    return null;
}

pub fn stats(ctx: *http.RequestCtx) !http.Response {
    if (try authorize(ctx)) |denied| return denied;
    const store = ctx.app.?.query_workbench orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    // Copy a bounded snapshot, then format outside the short counter lock.
    const snapshot = blk: {
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        break :blk .{ .entries = try ctx.allocator.a.dupe(workbench.Entry, store.entries[0..store.count]), .dropped = store.dropped };
    };
    const Item = struct {
        method: []const u8,
        routeTemplate: []const u8,
        shape: []const u8,
        executions: u64,
        stepNanoseconds: u64,
        maxStepNanoseconds: u64,
        slowExecutions: u64,
        repeatedShapes: u64,
        failedExecutions: u64,
    };
    const items = try ctx.allocator.a.alloc(Item, snapshot.entries.len);
    for (snapshot.entries, items) |*entry, *item| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, entry.fingerprint, .big);
        item.* = .{
            .method = entry.method,
            .routeTemplate = entry.route[0..entry.route_len],
            .shape = try ctx.allocator.a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower)),
            .executions = entry.executions,
            .stepNanoseconds = entry.total_ns,
            .maxStepNanoseconds = entry.max_ns,
            .slowExecutions = entry.slow,
            .repeatedShapes = entry.repeated,
            .failedExecutions = entry.failures,
        };
    }
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator.a, .{
        .items = items,
        .backend = "sqlite",
        .measurement = "prepared-statement-step-time",
        .activeBackend = @tagName(db.poolBackend(ctx.app.?.pool)),
        .maxEntries = store.limits.max_entries,
        .slowMilliseconds = store.limits.slow_ms,
        .droppedExecutions = snapshot.dropped,
        .repeatShapesPerRequest = 32,
    }, .{}) };
}

fn invalid(ctx: *http.RequestCtx) !http.Response {
    return ApiError.badRequest("Expected collection and optional equalityField, orderField, descending; no SQL or values accepted.").toResponse(ctx.allocator.a);
}
fn fieldAllowed(col: schema.Collection, name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    return std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "created") or std.mem.eql(u8, name, "updated") or schema.fieldByName(col, name) != null;
}

pub fn explain(ctx: *http.RequestCtx) !http.Response {
    if (try authorize(ctx)) |denied| return denied;
    if (db.poolBackend(ctx.app.?.pool) != .sqlite)
        return ApiError.withCode(501, .not_implemented, "Query-plan inspection supports SQLite only.").toResponse(ctx.allocator.a);
    if (ctx.body.len > 4096) return invalid(ctx);
    const Input = struct { collection: []const u8, equalityField: ?[]const u8 = null, orderField: ?[]const u8 = null, descending: bool = false };
    const input = std.json.parseFromSliceLeaky(Input, ctx.allocator.a, ctx.body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return invalid(ctx),
    };
    if (input.collection.len == 0 or input.collection.len > 255) return invalid(ctx);
    const app = ctx.app.?;
    var reader = try app.pool.acquireReader();
    defer app.pool.releaseReader(&reader);
    const col = (try collections.get(ctx.allocator.a, &reader, input.collection)) orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    if (input.equalityField) |field| if (!fieldAllowed(col, field)) return invalid(ctx);
    if (input.orderField) |field| if (!fieldAllowed(col, field)) return invalid(ctx);
    const qcol = try ddl.quoteIdent(ctx.allocator.a, col.name);
    const where = if (input.equalityField) |field| try std.fmt.allocPrint(ctx.allocator.a, " WHERE {s}=?1", .{try ddl.quoteIdent(ctx.allocator.a, field)}) else "";
    const order = if (input.orderField) |field| try std.fmt.allocPrint(ctx.allocator.a, " ORDER BY {s} {s}", .{ try ddl.quoteIdent(ctx.allocator.a, field), if (input.descending) @as([]const u8, "DESC") else "ASC" }) else "";
    // A generated SELECT shape, never EXPLAIN ANALYZE or caller-provided SQL.
    // No input values, functions, joins or expressions. Planning does not read
    // result rows or modify data. The NULL bind is deliberately value-agnostic.
    const sql = try std.fmt.allocPrintSentinel(ctx.allocator.a, "EXPLAIN QUERY PLAN SELECT \"id\" FROM {s}{s}{s} LIMIT 100;", .{ qcol, where, order }, 0);
    var stmt = try reader.prepare(sql);
    defer stmt.finalize();
    if (input.equalityField != null) try stmt.bindNull(1);
    const PlanRow = struct { id: i64, parent: i64, detail: []const u8 };
    var rows: [32]PlanRow = undefined;
    var count: usize = 0;
    var truncated = false;
    while (try stmt.step()) {
        if (count == rows.len) {
            truncated = true;
            break;
        }
        const detail = stmt.columnText(3);
        const bounded = boundedDetail(detail);
        if (bounded.len != detail.len) truncated = true;
        rows[count] = .{ .id = stmt.columnInt(0), .parent = stmt.columnInt(1), .detail = try ctx.allocator.a.dupe(u8, bounded) };
        count += 1;
    }
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.allocator.a, .{
        .items = rows[0..count],
        .backend = "sqlite",
        .scope = "structural-select-shape",
        .executesQuery = false,
        .includesAuthorizationPredicates = false,
        .truncated = truncated,
    }, .{}) };
}

fn boundedDetail(detail: []const u8) []const u8 {
    var len = @min(detail.len, 512);
    while (len > 0 and !std.unicode.utf8ValidateSlice(detail[0..len])) len -= 1;
    return detail[0..len];
}

test "plan details stay bounded valid UTF-8 at a multibyte boundary" {
    const detail = "a" ** 511 ++ "é";
    try std.testing.expectEqual(@as(usize, 511), boundedDetail(detail).len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(boundedDetail(detail)));
}
