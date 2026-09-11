//! Internal thumbnail prerequisite: read a bounded built-in local source only.
//! No fetch callbacks, remote spooling, output files or codec work. The configured
//! root may be a symlink; descendants never follow links. Descriptor metadata is
//! rechecked around reads; this is not protection against trusted hard links or
//! hostile writes that can preserve all observed filesystem metadata.
const std = @import("std");
const storage_mod = @import("storage.zig");

/// Owned result: caller frees the bytes with allocator. Every descriptor closes
/// before return. Paths must be single components, even for internal callers.
pub fn read(allocator: std.mem.Allocator, io: std.Io, storage: storage_mod.Storage, collection: []const u8, record_id: []const u8, filename: []const u8, max_bytes: usize) ![]u8 {
    if (max_bytes == 0) return error.InvalidSourceLimit;
    const opened = try open(io, storage, collection, record_id, filename);
    defer opened.file.close(io);
    return opened.read(allocator, io, max_bytes);
}

pub const Opened = struct {
    file: std.Io.File,
    stat: std.Io.File.Stat,
    pub fn read(self: Opened, allocator: std.mem.Allocator, io: std.Io, max_bytes: usize) ![]u8 {
        if (!same(self.stat, try self.file.stat(io))) return error.SourceChanged;
        const bytes = try readSized(allocator, io, self.file, self.stat.size, max_bytes);
        errdefer allocator.free(bytes);
        if (!same(self.stat, try self.file.stat(io))) return error.SourceChanged;
        return bytes;
    }
};

pub fn same(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}

/// Recheck both the opened object and its current pathname before returning a
/// representation or a cache validator. Does not allocate or read image bytes.
pub fn revalidate(opened: Opened, io: std.Io, storage: storage_mod.Storage, collection: []const u8, record_id: []const u8, filename: []const u8) !void {
    const current = try open(io, storage, collection, record_id, filename);
    defer current.file.close(io);
    if (!same(opened.stat, current.stat) or !same(opened.stat, try opened.file.stat(io))) return error.SourceChanged;
}

/// Owns the returned descriptor; caller closes it. Metadata and bounded reads
/// share one opened object so replacement cannot relabel different source bytes.
pub fn open(io: std.Io, storage: storage_mod.Storage, collection: []const u8, record_id: []const u8, filename: []const u8) !Opened {
    const local = storage_mod.LocalStorage.fromStorage(storage) orelse return error.UnsupportedSourceStorage;
    for ([_][]const u8{ collection, record_id, filename }) |part| {
        if (!validComponent(part)) return error.InvalidSourcePath;
    }
    var root = try std.Io.Dir.cwd().openDir(io, local.root, .{});
    defer root.close(io);
    var col_dir = try root.openDir(io, collection, .{ .follow_symlinks = false });
    defer col_dir.close(io);
    var rec_dir = try col_dir.openDir(io, record_id, .{ .follow_symlinks = false });
    defer rec_dir.close(io);
    // Io.Dir.openFile has no nonblocking-open option. A FIFO may block before
    // fstat, so use the supported Linux/macOS POSIX primitive for this one open.
    const fd = try std.posix.openat(rec_dir.handle, filename, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true, .NOCTTY = true }, 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.SourceNotRegular;
    return .{ .file = file, .stat = stat };
}

fn validComponent(part: []const u8) bool {
    return part.len > 0 and part.len <= 255 and
        !std.mem.eql(u8, part, ".") and !std.mem.eql(u8, part, "..") and
        std.mem.indexOfAny(u8, part, "/\\\x00") == null;
}

/// Read exactly the observed size, then probe one byte to reject growth. No
/// buffered read-ahead can consume an arbitrarily grown file. Concurrent writes
/// after the EOF probe remain outside this bounded-read guarantee.
fn readSized(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, observed_size: u64, max_bytes: usize) ![]u8 {
    if (observed_size > max_bytes) return error.SourceTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(observed_size));
    errdefer allocator.free(bytes);
    var reader = file.reader(io, &.{});
    reader.interface.readSliceAll(bytes) catch |err| switch (err) {
        error.EndOfStream => return error.SourceChanged,
        else => return err,
    };
    var probe: [1]u8 = undefined;
    if (try reader.interface.readSliceShort(&probe) == 0) return bytes;
    return if (observed_size == max_bytes) error.SourceTooLarge else error.SourceChanged;
}

test "thumbnail source bounds bytes and never invokes custom storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var local = storage_mod.LocalStorage.init(root);
    const storage = local.storage();
    try storage.put(io, "images", "r1", "source.png", "abcdef");
    const bytes = try read(a, io, storage, "images", "r1", "source.png", 6);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("abcdef", bytes);
    try std.testing.expectError(error.SourceTooLarge, read(a, io, storage, "images", "r1", "source.png", 5));
    try std.testing.expectError(error.InvalidSourceLimit, read(a, io, storage, "images", "r1", "source.png", 0));
    try std.testing.expectError(error.FileNotFound, read(a, io, storage, "images", "r1", "missing", 6));
    try std.testing.expectError(error.InvalidSourcePath, read(a, io, storage, "../images", "r1", "source.png", 6));
    try std.testing.expectError(error.InvalidSourcePath, read(a, io, storage, "images", "..", "source.png", 6));
    try storage.put(io, "images", "r1", "empty.png", "");
    const empty = try read(a, io, storage, "images", "r1", "empty.png", 6);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    for ([_][]const u8{ "", ".", "..", "../source.png", "a/b", "a\\b", "a\x00b" }) |name|
        try std.testing.expectError(error.InvalidSourcePath, read(a, io, storage, "images", "r1", name, 6));
    const Never = struct {
        fn fetch(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !?[]const u8 {
            @panic("thumbnail source must not call fetch");
        }
    };
    var custom = storage.vtable.*;
    custom.fetch = Never.fetch;
    try std.testing.expectError(error.UnsupportedSourceStorage, read(a, io, .{ .ctx = &local, .vtable = &custom }, "images", "r1", "source.png", 6));
}

test "thumbnail source rejects symlink descendants and nonregular files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var local = storage_mod.LocalStorage.init(root);
    try local.storage().put(io, "images", "r1", "source.png", "abc");
    try tmp.dir.symLink(io, ".", "root-link", .{ .is_directory = true });
    const linked_root = try std.fs.path.join(a, &.{ root, "root-link" });
    defer a.free(linked_root);
    var root_alias = storage_mod.LocalStorage.init(linked_root);
    const aliased = try read(a, io, root_alias.storage(), "images", "r1", "source.png", 3);
    defer a.free(aliased);
    try std.testing.expectEqualStrings("abc", aliased);
    try tmp.dir.symLink(io, "images", "linked-col", .{ .is_directory = true });
    try tmp.dir.symLink(io, "r1", "images/linked-rec", .{ .is_directory = true });
    try tmp.dir.symLink(io, "source.png", "images/r1/linked.png", .{});
    for ([_][3][]const u8{ .{ "linked-col", "r1", "source.png" }, .{ "images", "linked-rec", "source.png" }, .{ "images", "r1", "linked.png" } }) |parts| {
        if (read(a, io, local.storage(), parts[0], parts[1], parts[2], 3)) |bytes| {
            a.free(bytes);
            return error.FollowedSourceSymlink;
        } else |err| switch (err) {
            error.SymLinkLoop, error.NotDir => {},
            else => return err,
        }
    }
    try tmp.dir.createDir(io, "images/r1/directory", .default_dir);
    try std.testing.expectError(error.SourceNotRegular, read(a, io, local.storage(), "images", "r1", "directory", 3));
    const Libc = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: std.posix.mode_t) c_int;
    };
    const fifo = try std.fmt.allocPrintSentinel(a, "{s}/images/r1/fifo", .{root}, 0);
    defer a.free(fifo);
    if (Libc.mkfifo(fifo, 0o600) != 0) return error.FifoCreationFailed;
    try std.testing.expectError(error.SourceNotRegular, read(a, io, local.storage(), "images", "r1", "fifo", 3));
}

test "thumbnail source rejects truncation and growth after stat" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    inline for (.{ "ab", "abcdefg" }) |changed| {
        try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "abcdef" });
        const file = try tmp.dir.openFile(io, "source", .{});
        defer file.close(io);
        const observed = try file.stat(io);
        try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = changed });
        try std.testing.expectError(error.SourceChanged, readSized(a, io, file, observed.size, 8));
    }
    const grown = try tmp.dir.openFile(io, "source", .{});
    defer grown.close(io);
    try std.testing.expectError(error.SourceTooLarge, readSized(a, io, grown, 6, 6));
}

test "thumbnail source allocation failures close descriptors and free output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var local = storage_mod.LocalStorage.init(root);
    try local.storage().put(std.testing.io, "images", "r1", "source.png", "abcdef");
    const Harness = struct {
        fn run(a: std.mem.Allocator, storage: storage_mod.Storage) !void {
            const bytes = try read(a, std.testing.io, storage, "images", "r1", "source.png", 6);
            defer a.free(bytes);
            try std.testing.expectEqualStrings("abcdef", bytes);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{local.storage()});
}

test "thumbnail source revalidation detects replacement deletion and changed descriptors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var local = storage_mod.LocalStorage.init(root);
    const storage = local.storage();
    try storage.put(io, "images", "r1", "source.png", "abc");
    const opened = try open(io, storage, "images", "r1", "source.png");
    defer opened.file.close(io);
    try revalidate(opened, io, storage, "images", "r1", "source.png");
    // Keep the old descriptor alive while deterministically replacing its name
    // with a same-sized object; no scheduling or timestamp resolution assumed.
    try tmp.dir.deleteFile(io, "images/r1/source.png");
    try storage.put(io, "images", "r1", "source.png", "xyz");
    try std.testing.expectError(error.SourceChanged, revalidate(opened, io, storage, "images", "r1", "source.png"));
    const replacement = try open(io, storage, "images", "r1", "source.png");
    defer replacement.file.close(io);
    try revalidate(replacement, io, storage, "images", "r1", "source.png");
    try tmp.dir.writeFile(io, .{ .sub_path = "images/r1/source.png", .data = "longer" });
    try std.testing.expectError(error.SourceChanged, revalidate(replacement, io, storage, "images", "r1", "source.png"));
    try tmp.dir.deleteFile(io, "images/r1/source.png");
    try std.testing.expectError(error.FileNotFound, revalidate(replacement, io, storage, "images", "r1", "source.png"));
}
