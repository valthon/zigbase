const std = @import("std");

/// Backend-agnostic blob storage for record files. `fetch` returns a local filesystem
/// path whose contents ARE the file — materializing it locally first if necessary
/// (remote backends spool to a local cache); `null` = the backend has no such object.
/// (0.10.0, Breaking: was `localPath(ctx, alloc, …)` — the rename is forced anyway,
/// since a remote backend needs the `io` for network/disk I/O.)
pub const Storage = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Optional, read-only inventory. The result owns its keys and cursor;
        /// missing callback preserves compatibility with existing plugins.
        inventory: ?*const fn (ctx: *anyopaque, io: std.Io, alloc: std.mem.Allocator, cursor: ?[]const u8, limit: u16) anyerror!InventoryPage = null,
        put: *const fn (ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8, bytes: []const u8) anyerror!void,
        fetch: *const fn (ctx: *anyopaque, io: std.Io, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8,
        delete: *const fn (ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!void,
        deleteRecord: *const fn (ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8) anyerror!void,
        /// OPTIONAL: presign a time-limited GET URL for the object so an authorized download can be
        /// served as a 302 redirect instead of proxying the bytes. `null` (the default) = the
        /// backend cannot presign — the serve path falls back to `fetch`+stream. Returning null at
        /// call time is also allowed (e.g. a backend that presigns only some objects). A signing
        /// failure propagates as an error (the caller decides). Defaulting to null keeps existing
        /// `VTable{ ... }` literals valid (backward-compatible for custom storage plugins).
        presignGetUrl: ?*const fn (ctx: *anyopaque, io: std.Io, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8, expires_seconds: u32) anyerror!?[]const u8 = null,
    };

    pub const InventoryItem = struct { key: []const u8, bytes: u64 };
    pub const InventoryPage = struct {
        items: []InventoryItem,
        nextCursor: ?[]const u8 = null,
        pub fn deinit(self: InventoryPage, alloc: std.mem.Allocator) void {
            for (self.items) |item| alloc.free(item.key);
            alloc.free(self.items);
            if (self.nextCursor) |cursor| alloc.free(cursor);
        }
    };

    pub fn inventory(self: Storage, io: std.Io, alloc: std.mem.Allocator, cursor: ?[]const u8, limit: u16) !InventoryPage {
        if (limit == 0 or limit > 1000) return error.InvalidInventoryLimit;
        if (cursor) |c| if (c.len == 0 or c.len > 4096) return error.InvalidInventoryCursor;
        const callback = self.vtable.inventory orelse return error.InventoryUnsupported;
        const result = try callback(self.ctx, io, alloc, cursor, limit);
        errdefer result.deinit(alloc);
        if (result.items.len > limit) return error.InvalidInventoryPage;
        if (result.nextCursor) |next| {
            if (next.len == 0 or next.len > 4096 or (cursor != null and std.mem.eql(u8, next, cursor.?))) return error.InvalidInventoryPage;
        }
        return result;
    }

    pub fn put(self: Storage, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8, bytes: []const u8) anyerror!void {
        return self.vtable.put(self.ctx, io, col, record_id, filename, bytes);
    }
    pub fn fetch(self: Storage, io: std.Io, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8 {
        return self.vtable.fetch(self.ctx, io, alloc, col, record_id, filename);
    }
    pub fn delete(self: Storage, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!void {
        return self.vtable.delete(self.ctx, io, col, record_id, filename);
    }
    pub fn deleteRecord(self: Storage, io: std.Io, col: []const u8, record_id: []const u8) anyerror!void {
        return self.vtable.deleteRecord(self.ctx, io, col, record_id);
    }
    /// Presign a GET URL for the object, or `null` if the backend cannot presign (the vtable field
    /// is null — e.g. local disk). The caller (api/files.serve) 302-redirects to a non-null URL and
    /// otherwise falls back to the proxy path. A signing failure propagates as an error.
    pub fn presignGetUrl(self: Storage, io: std.Io, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8, expires_seconds: u32) anyerror!?[]const u8 {
        const f = self.vtable.presignGetUrl orelse return null;
        return f(self.ctx, io, alloc, col, record_id, filename, expires_seconds);
    }
};

/// Local filesystem backend rooted at `root` (absolute). Layout: <root>/<col>/<record_id>/<filename>.
/// col/record_id are validated ids and filename is always a naming-sanitized stored name, so no
/// client string is ever a raw path component.
pub const LocalStorage = struct {
    root: []const u8,

    pub fn init(root: []const u8) LocalStorage {
        return .{ .root = root };
    }

    pub fn storage(self: *LocalStorage) Storage {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Storage.VTable{
        .put = put,
        .fetch = fetch,
        .delete = delete,
        .deleteRecord = deleteRecord,
        .inventory = if (@import("build_options").file_inventory) @import("local_inventory.zig").page else null,
    };

    fn dirPath(alloc: std.mem.Allocator, root: []const u8, col: []const u8, record_id: []const u8) ![]u8 {
        return std.fs.path.join(alloc, &.{ root, col, record_id });
    }

    fn put(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8, bytes: []const u8) anyerror!void {
        const self: *LocalStorage = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const a = fba.allocator();
        const dir = try dirPath(a, self.root, col, record_id);
        var cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, dir);
        const path = try std.fs.path.join(a, &.{ dir, filename });
        try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    fn fetch(ctx: *anyopaque, io: std.Io, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8 {
        _ = io;
        const self: *LocalStorage = @ptrCast(@alignCast(ctx));
        return try std.fs.path.join(alloc, &.{ self.root, col, record_id, filename });
    }

    fn delete(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!void {
        const self: *LocalStorage = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const a = fba.allocator();
        const path = try std.fs.path.join(a, &.{ self.root, col, record_id, filename });
        std.Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }

    fn deleteRecord(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8) anyerror!void {
        const self: *LocalStorage = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const a = fba.allocator();
        const dir = try dirPath(a, self.root, col, record_id);
        // deleteTree treats a missing target as a no-op (no FileNotFound in its error set).
        try std.Io.Dir.cwd().deleteTree(io, dir);
    }
};

test "LocalStorage put/fetch/read/delete/deleteRecord round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);

    var local = LocalStorage.init(root);
    const st = local.storage();

    try st.put(std.testing.io, "posts", "rec1", "cover_ab12.png", "PNGDATA");
    const p = (try st.fetch(std.testing.io, a, "posts", "rec1", "cover_ab12.png")).?;
    defer a.free(p);
    const back = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, a, .limited(1 << 20));
    defer a.free(back);
    try std.testing.expectEqualStrings("PNGDATA", back);

    try st.delete(std.testing.io, "posts", "rec1", "cover_ab12.png");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, a, .limited(16)));

    try st.put(std.testing.io, "posts", "rec2", "a.txt", "A");
    try st.put(std.testing.io, "posts", "rec2", "b.txt", "B");
    try st.deleteRecord(std.testing.io, "posts", "rec2");
    const dir2 = (try st.fetch(std.testing.io, a, "posts", "rec2", "a.txt")).?;
    defer a.free(dir2);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, dir2, a, .limited(16)));

    try st.delete(std.testing.io, "posts", "ghost", "none.txt"); // missing -> no-op
}

test "LocalStorage does not presign (wrapper returns null)" {
    var local = LocalStorage.init("/tmp/root");
    const st = local.storage();
    const url = try st.presignGetUrl(std.testing.io, std.testing.allocator, "posts", "rec1", "a.png", 900);
    try std.testing.expect(url == null);
}

test "inventory capability is absent in a default binary and validates bounds" {
    var local = LocalStorage.init("/tmp/unused-storage-inventory");
    const st = local.storage();
    try std.testing.expectError(error.InvalidInventoryLimit, st.inventory(std.testing.io, std.testing.allocator, null, 0));
    try std.testing.expectError(error.InvalidInventoryLimit, st.inventory(std.testing.io, std.testing.allocator, null, 1001));
    try std.testing.expectError(error.InvalidInventoryCursor, st.inventory(std.testing.io, std.testing.allocator, "", 1));
    if (!@import("build_options").file_inventory)
        try std.testing.expectError(error.InventoryUnsupported, st.inventory(std.testing.io, std.testing.allocator, null, 1));
}
