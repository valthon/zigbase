//! Inventory is an observation, never proof that a blob is safe to delete.
const std = @import("std");
const db = @import("../db.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const Storage = @import("storage.zig").Storage;

pub const Reference = enum { referenced, candidate_unreferenced, unknown };

/// Self-freeing scratch: parsed collection/record graphs live only for this one
/// lookup. Unknown layouts/read failures must not be promoted to orphan claims.
pub fn reference(alloc: std.mem.Allocator, conn: *db.Db, key: []const u8) Reference {
    var parts = std.mem.splitScalar(u8, key, '/');
    const col_name = parts.next() orelse return .unknown;
    const rid = parts.next() orelse return .unknown;
    const name = parts.next() orelse return .unknown;
    if (parts.next() != null or col_name.len == 0 or rid.len == 0 or name.len == 0) return .unknown;
    for ([_][]const u8{ col_name, rid, name }) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, '\\') != null) return .unknown;
    }
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    const col = (collections.get(a, conn, col_name) catch return .unknown) orelse return .candidate_unreferenced;
    // Maintenance references are physical, not public visibility. Expired rows
    // still own blobs until GC deletes them; hidden file fields own blobs too.
    // Project only file columns, making their copies visible to the at-rest
    // decoder without changing the collection or exposing unrelated fields.
    var file_fields: std.ArrayList(@import("../schema.zig").Field) = .empty;
    defer file_fields.deinit(a);
    for (col.fields) |field| {
        if (field.fieldType() != .file) continue;
        var visible = field;
        visible.hidden = false;
        file_fields.append(a, visible) catch return .unknown;
    }
    var physical = col;
    physical.fields = file_fields.items;
    const record = (records.getAtRest(a, conn, physical, rid) catch return .unknown) orelse return .candidate_unreferenced;
    if (record != .object) return .unknown;
    for (col.fields) |field| {
        if (field.fieldType() != .file) continue;
        const value = record.object.get(field.name) orelse continue;
        switch (value) {
            .string => |s| if (std.mem.eql(u8, s, name)) return .referenced,
            .array => |array| for (array.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, name)) return .referenced;
            },
            else => {},
        }
    }
    return .candidate_unreferenced;
}

test "inventory preserves physical references on expired TTL rows and hidden file fields" {
    const a = std.testing.allocator;
    var conn = try db.Db.open(":memory:");
    defer conn.close();
    try @import("../migrations.zig").run(&conn);
    const col = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "physical_files",
        .options = .{ .ttl_field = "expires" },
        .fields = &.{
            .{ .id = "expires", .name = "expires", .options = .{ .date = .{} } },
            .{ .id = "photo", .name = "photo", .options = .{ .file = .{} } },
            .{ .id = "hidden", .name = "secret_photo", .hidden = true, .options = .{ .file = .{} } },
            .{ .id = "gallery", .name = "secret_gallery", .hidden = true, .options = .{ .file = .{ .maxSelect = 3 } } },
        },
    });
    defer col.deinit(a);
    try conn.exec("INSERT INTO physical_files (id, created, updated, expires, photo, secret_photo, secret_gallery) VALUES ('expired','','','1970-01-01T00:00:00Z','public.png','hidden.png','[\"a.png\",\"b.png\"]');");
    try std.testing.expect((try records.get(a, &conn, col, "expired")) == null);
    for ([_][]const u8{ "physical_files/expired/public.png", "physical_files/expired/hidden.png", "physical_files/expired/a.png", "physical_files/expired/b.png" }) |key|
        try std.testing.expectEqual(Reference.referenced, reference(a, &conn, key));
    try std.testing.expectEqual(Reference.candidate_unreferenced, reference(a, &conn, "physical_files/expired/absent.png"));
    try conn.exec("UPDATE physical_files SET expires=NULL WHERE id='expired';");
    // Hiding a file is independently insufficient to make it an orphan.
    try std.testing.expectEqual(Reference.referenced, reference(a, &conn, "physical_files/expired/hidden.png"));
    try std.testing.expectEqual(Reference.referenced, reference(a, &conn, "physical_files/expired/b.png"));
}

/// Caller owns the returned JSON; borrows page keys only while rendering.
pub fn render(alloc: std.mem.Allocator, conn: *db.Db, page: Storage.InventoryPage) ![]u8 {
    // Keep keys/cursors strings in JSON; never silently serialize byte arrays.
    if (page.nextCursor) |cursor| if (!std.unicode.utf8ValidateSlice(cursor)) return error.InvalidInventoryUtf8;
    for (page.items) |item| if (!std.unicode.utf8ValidateSlice(item.key)) return error.InvalidInventoryUtf8;
    const Item = struct { key: []const u8, bytes: u64, reference: Reference };
    const items = try alloc.alloc(Item, page.items.len);
    defer alloc.free(items);
    var bytes: u64 = 0;
    var candidates: usize = 0;
    var unknown: usize = 0;
    for (page.items, 0..) |item, i| {
        const state = reference(alloc, conn, item.key);
        items[i] = .{ .key = item.key, .bytes = item.bytes, .reference = state };
        bytes = try std.math.add(u64, bytes, item.bytes);
        if (state == .candidate_unreferenced) candidates += 1;
        if (state == .unknown) unknown += 1;
    }
    return std.json.Stringify.valueAlloc(alloc, .{
        .items = items,
        .nextCursor = page.nextCursor,
        .hasNext = page.nextCursor != null,
        .usage = .{ .scope = "page", .objects = items.len, .bytes = bytes, .candidateUnreferenced = candidates, .unknown = unknown },
        .consistency = "live-observation-not-snapshot",
        .warning = "Unreferenced candidates may be in-flight uploads or concurrent changes. No object is proven safe to delete.",
    }, .{});
}

test "reference classification and usage never treat unknown layouts as orphan proof" {
    const a = std.testing.allocator;
    var conn = try db.Db.open(":memory:");
    defer conn.close();
    try @import("../migrations.zig").run(&conn);
    const col = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "images",
        .fields = &.{.{ .id = "photo", .name = "photo", .options = .{ .file = .{} } }},
    });
    defer col.deinit(a);
    try conn.exec("INSERT INTO images (id, created, updated, photo) VALUES ('r1','','','a.png');");
    try std.testing.expectEqual(Reference.referenced, reference(a, &conn, "images/r1/a.png"));
    try std.testing.expectEqual(Reference.candidate_unreferenced, reference(a, &conn, "images/r1/new.png"));
    try std.testing.expectEqual(Reference.candidate_unreferenced, reference(a, &conn, "missing/r1/a.png"));
    try std.testing.expectEqual(Reference.unknown, reference(a, &conn, "../r1/a.png"));
    const items = [_]Storage.InventoryItem{ .{ .key = "images/r1/a.png", .bytes = 4 }, .{ .key = "images/r1/new.png", .bytes = 3 } };
    const output = try render(a, &conn, .{ .items = @constCast(&items) });
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"bytes\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"candidateUnreferenced\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "not-snapshot") != null);
}
