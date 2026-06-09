const std = @import("std");

/// Backend-agnostic blob storage for record files. `localPath` returns a filesystem path for
/// backends that have one (so server.zig can sendFile); non-local backends return null.
pub const Storage = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8, bytes: []const u8) anyerror!void,
        localPath: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8,
        delete: *const fn (ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!void,
        deleteRecord: *const fn (ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8) anyerror!void,
    };

    pub fn put(self: Storage, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8, bytes: []const u8) anyerror!void {
        return self.vtable.put(self.ctx, io, col, record_id, filename, bytes);
    }
    pub fn localPath(self: Storage, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8 {
        return self.vtable.localPath(self.ctx, alloc, col, record_id, filename);
    }
    pub fn delete(self: Storage, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!void {
        return self.vtable.delete(self.ctx, io, col, record_id, filename);
    }
    pub fn deleteRecord(self: Storage, io: std.Io, col: []const u8, record_id: []const u8) anyerror!void {
        return self.vtable.deleteRecord(self.ctx, io, col, record_id);
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

    const vtable = Storage.VTable{ .put = put, .localPath = localPath, .delete = delete, .deleteRecord = deleteRecord };

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

    fn localPath(ctx: *anyopaque, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8 {
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

test "LocalStorage put/localPath/read/delete/deleteRecord round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);

    var local = LocalStorage.init(root);
    const st = local.storage();

    try st.put(std.testing.io, "posts", "rec1", "cover_ab12.png", "PNGDATA");
    const p = (try st.localPath(a, "posts", "rec1", "cover_ab12.png")).?;
    const back = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, a, .limited(1 << 20));
    try std.testing.expectEqualStrings("PNGDATA", back);

    try st.delete(std.testing.io, "posts", "rec1", "cover_ab12.png");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, a, .limited(16)));

    try st.put(std.testing.io, "posts", "rec2", "a.txt", "A");
    try st.put(std.testing.io, "posts", "rec2", "b.txt", "B");
    try st.deleteRecord(std.testing.io, "posts", "rec2");
    const dir2 = (try st.localPath(a, "posts", "rec2", "a.txt")).?;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, dir2, a, .limited(16)));

    try st.delete(std.testing.io, "posts", "ghost", "none.txt"); // missing -> no-op
}
