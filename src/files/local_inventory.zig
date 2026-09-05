//! Read-only, bounded-memory inventory of the three-level record-file layout.
const std = @import("std");
const storage = @import("storage.zig");
const Item = storage.Storage.InventoryItem;
const ScanError = std.mem.Allocator.Error || std.Io.Dir.Iterator.Error || std.Io.Dir.StatFileError || std.Io.Dir.OpenError || error{InventoryScanLimit};

const Scan = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    cursor: []const u8,
    limit: usize,
    seen: usize = 0,
    items: std.ArrayList(Item) = .empty,

    fn walk(self: *Scan, dir: std.Io.Dir, prefix: []const u8, depth: u8) ScanError!void {
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            self.seen += 1;
            if (self.seen > 100_000) return error.InventoryScanLimit;
            try self.visit(dir, prefix, depth, entry.name, entry.kind);
        }
    }

    fn visit(self: *Scan, dir: std.Io.Dir, prefix: []const u8, depth: u8, name: []const u8, hint: std.Io.File.Kind) !void {
        if (hint != .file and hint != .directory and hint != .unknown) return;
        // d_type is only a hint (DT_UNKNOWN is common on network filesystems).
        // Resolve actual type without following links, including replacement races.
        const stat = dir.statFile(self.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stat.kind != .file and stat.kind != .directory) return;
        const key = if (prefix.len == 0) try self.alloc.dupe(u8, name) else try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ prefix, name });
        defer self.alloc.free(key);
        if (stat.kind == .directory) {
            if (depth == 2) return;
            var child = dir.openDir(self.io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.SymLinkLoop => return,
                else => return err,
            };
            defer child.close(self.io);
            try self.walk(child, key, depth + 1);
            return;
        }
        if (std.mem.order(u8, key, self.cursor) != .gt) return;
        var pos: usize = 0;
        while (pos < self.items.items.len and std.mem.order(u8, self.items.items[pos].key, key) == .lt) : (pos += 1) {}
        if (pos > self.limit) return;
        const owned = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(owned);
        try self.items.insert(self.alloc, pos, .{ .key = owned, .bytes = stat.size });
        if (self.items.items.len > self.limit + 1) {
            const removed = self.items.pop().?;
            self.alloc.free(removed.key);
        }
    }
};

/// Owned result. Rescans at most 100000 directory entries, retaining limit+1
/// lexically ordered keys. The configured root may be a symlink; descendants
/// never follow symlinks, including directory replacement races.
pub fn page(ctx: *anyopaque, io: std.Io, alloc: std.mem.Allocator, cursor: ?[]const u8, limit: u16) !storage.Storage.InventoryPage {
    const local: *storage.LocalStorage = @ptrCast(@alignCast(ctx));
    var root = std.Io.Dir.cwd().openDir(io, local.root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .items = try alloc.alloc(Item, 0) },
        else => return err,
    };
    defer root.close(io);
    var scan = Scan{ .io = io, .alloc = alloc, .cursor = cursor orelse "", .limit = limit };
    defer {
        for (scan.items.items) |item| alloc.free(item.key);
        scan.items.deinit(alloc);
    }
    try scan.walk(root, "", 0);
    const next = if (scan.items.items.len > limit) try alloc.dupe(u8, scan.items.items[limit - 1].key) else null;
    errdefer if (next) |value| alloc.free(value);
    if (scan.items.items.len > limit) alloc.free(scan.items.pop().?.key);
    return .{ .items = try scan.items.toOwnedSlice(alloc), .nextCursor = next };
}

test "local inventory paginates sorted keys and reports byte usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var local = storage.LocalStorage.init(root);
    const st = local.storage();
    try st.put(std.testing.io, "posts", "r1", "z.txt", "last");
    try st.put(std.testing.io, "posts", "r1", "a.txt", "abc");
    try tmp.dir.symLink(std.testing.io, "/etc", "outside", .{ .is_directory = true });
    try tmp.dir.symLink(std.testing.io, "/etc/passwd", "posts/r1/linked.txt", .{});
    const first = try page(&local, std.testing.io, a, null, 1);
    defer first.deinit(a);
    try std.testing.expectEqualStrings("posts/r1/a.txt", first.items[0].key);
    try std.testing.expectEqual(@as(u64, 3), first.items[0].bytes);
    const second = try page(&local, std.testing.io, a, first.nextCursor, 1);
    defer second.deinit(a);
    try std.testing.expectEqualStrings("posts/r1/z.txt", second.items[0].key);
    try std.testing.expect(second.nextCursor == null);
    var scan = Scan{ .io = std.testing.io, .alloc = a, .cursor = "", .limit = 10 };
    defer {
        for (scan.items.items) |item| a.free(item.key);
        scan.items.deinit(a);
    }
    try scan.visit(tmp.dir, "", 0, "posts", .unknown);
    try scan.visit(tmp.dir, "", 0, "outside", .unknown);
    try scan.visit(tmp.dir, "", 0, "posts/r1/linked.txt", .unknown);
    try std.testing.expectEqual(@as(usize, 2), scan.items.items.len);
    try scan.visit(tmp.dir, "", 0, "posts/r1/a.txt", .unknown);
    try std.testing.expectEqual(@as(usize, 3), scan.items.items.len);
}
