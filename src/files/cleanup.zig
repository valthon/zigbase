//! Opt-in HTTP file cleanup, persisted atomically with record mutations.
const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const queue = @import("../queue/queue.zig");
const durable = @import("../queue/durable.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Payload = struct { collection: []const u8, collection_id: []const u8, record: []const u8, filename: ?[]const u8 = null };

fn safeComponent(s: []const u8) bool {
    if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    return true;
}

fn contains(value: std.json.Value, filename: []const u8) bool {
    return switch (value) {
        .string => std.mem.eql(u8, value.string, filename),
        .array => blk: {
            for (value.array.items) |item| if (contains(item, filename)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn referenced(col: schema.Collection, row: ?std.json.Value, filename: []const u8) bool {
    const record = row orelse return false;
    if (record != .object) return false;
    for (col.fields) |field| if (field.options == .file) {
        if (record.object.get(field.name)) |v| if (contains(v, filename)) return true;
    };
    return false;
}

/// Self-freeing; caller owns the transaction, so enqueue failures roll back the mutation.
pub fn enqueueRemoved(alloc: std.mem.Allocator, w: *db.Db, io: std.Io, def: queue.QueueDef, col: schema.Collection, rid: []const u8, old: std.json.Value, new: ?std.json.Value) !void {
    if (!w.inTransaction()) return error.FileCleanupRequiresTransaction;
    if (new == null) {
        const payload = try std.json.Stringify.valueAlloc(alloc, Payload{ .collection = col.name, .collection_id = col.id, .record = rid }, .{});
        defer alloc.free(payload);
        _ = try durable.enqueue(w, io, def, "file_cleanup", payload, @import("../clock.zig").nowUnix(io));
        return;
    }
    if (old != .object) return;
    for (col.fields) |field| if (field.options == .file) {
        const value = old.object.get(field.name) orelse continue;
        switch (value) {
            .string => try enqueueName(alloc, w, io, def, col, rid, value.string, new),
            .array => for (value.array.items) |item| {
                if (item == .string) try enqueueName(alloc, w, io, def, col, rid, item.string, new);
            },
            else => {},
        }
    };
}

fn enqueueName(alloc: std.mem.Allocator, w: *db.Db, io: std.Io, def: queue.QueueDef, col: schema.Collection, rid: []const u8, name: []const u8, new: ?std.json.Value) !void {
    if (name.len == 0 or referenced(col, new, name)) return;
    const payload = try std.json.Stringify.valueAlloc(alloc, Payload{ .collection = col.name, .collection_id = col.id, .record = rid, .filename = name }, .{});
    defer alloc.free(payload);
    _ = try durable.enqueue(w, io, def, "file_cleanup", payload, @import("../clock.zig").nowUnix(io));
}

pub fn jobHandler(ctx: *Ctx, payload: []const u8) !void {
    const parsed = try std.json.parseFromSlice(Payload, ctx.arena.a, payload, .{});
    defer parsed.deinit();
    if (!safeComponent(parsed.value.collection) or !safeComponent(parsed.value.record)) return error.InvalidCleanupPath;
    if (parsed.value.filename) |name| if (!safeComponent(name)) return error.InvalidCleanupPath;
    const storage = ctx.app.storage orelse return error.FileCleanupStorageUnavailable;
    const w = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();
    try w.beginImmediate();
    defer if (w.inTransaction()) w.rollback() catch |err| std.log.err("file cleanup rollback failed: {s}", .{@errorName(err)});
    // Cleanup yields to contention instead of pinning the process-wide writer.
    if (db.dbDialect(w).kind == .postgres) try w.exec("SET LOCAL lock_timeout = '250ms';");
    const p = parsed.value;
    var col = (try collections.get(ctx.arena.a, w, p.collection)) orelse return;
    defer col.deinit(ctx.arena.a);
    if (!std.mem.eql(u8, col.id, p.collection_id)) return;
    if (db.dbDialect(w).kind == .postgres) {
        const ident = try @import("../ddl.zig").quoteIdent(ctx.arena.a, col.name);
        defer ctx.arena.a.free(ident);
        const sql = try std.fmt.allocPrintSentinel(ctx.arena.a, "LOCK TABLE {s} IN SHARE ROW EXCLUSIVE MODE;", .{ident}, 0);
        defer ctx.arena.a.free(sql);
        try w.exec(sql);
        // Match DDL's data-table -> metadata ordering. Revalidate the optimistic
        // lookup after both locks; dropped/renamed tables fail and retry safely.
        try w.exec("LOCK TABLE \"_collections\" IN SHARE MODE;");
        const current = (try collections.get(ctx.arena.a, w, col.name)) orelse return;
        col.deinit(ctx.arena.a);
        col = current;
        if (!std.mem.eql(u8, col.id, p.collection_id)) return;
    }
    // The request arena owns the record graph. The lock closes the gap between
    // checking references and deleting bytes, including across PostgreSQL instances.
    const row = try records.getFilesPhysical(ctx.arena.a, w, col, p.record);
    // get accepts either an ID or a name; only the resolved name identifies
    // the storage prefix whose references were checked above.
    if (p.filename) |name| {
        if (referenced(col, row, name)) return;
        try storage.delete(ctx.app.io, col.name, p.record, name);
    } else {
        if (row != null) return;
        try storage.deleteRecord(ctx.app.io, col.name, p.record);
    }
    try w.commit();
}

test "cleanup keeps references in any file field" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"a\":\"\",\"b\":[\"kept.txt\"]}", .{});
    defer parsed.deinit();
    const col = schema.Collection{ .id = "test", .name = "files", .fields = &.{ .{ .id = "a", .name = "a", .options = .{ .file = .{} } }, .{ .id = "b", .name = "b", .options = .{ .file = .{} } } } };
    try std.testing.expect(referenced(col, parsed.value, "kept.txt"));
    try std.testing.expect(!referenced(col, parsed.value, "gone.txt"));
}
