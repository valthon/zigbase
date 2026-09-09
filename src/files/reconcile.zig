//! Local SQLite maintenance only. Age is an operator grace period, NOT proof
//! against an in-flight upload. Apply requires an exclusive storage lease and
//! SQLite writer transaction supplied by the CLI for the entire bounded batch.
const std = @import("std");
const db = @import("../db.zig");
const inventory = @import("inventory.zig");
const storage = @import("storage.zig");
const collections = @import("../collections.zig");

pub const Outcome = enum { candidate, referenced, recent, unknown, changed, deleted, missing, failed };
pub const Item = struct { key: []const u8, bytes: u64, modifiedAt: ?i64 = null, outcome: Outcome, failure: ?[]const u8 = null };
pub const Result = struct {
    output: []u8,
    failures: usize,
    pub fn deinit(self: Result, alloc: std.mem.Allocator) void {
        alloc.free(self.output);
    }
};

fn component(part: []const u8) bool {
    if (part.len == 0 or part.len > 255 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    return true;
}

const File = struct {
    dir: std.Io.Dir,
    name: []const u8,
    stat: std.Io.File.Stat,
    fn open(io: std.Io, root: std.Io.Dir, key: []const u8) !File {
        var parts = std.mem.splitScalar(u8, key, '/');
        const col = parts.next() orelse return error.UnknownLayout;
        const rid = parts.next() orelse return error.UnknownLayout;
        const name = parts.next() orelse return error.UnknownLayout;
        if (parts.next() != null or !component(col) or !component(rid) or !component(name)) return error.UnknownLayout;
        var collection_dir = try root.openDir(io, col, .{ .follow_symlinks = false });
        defer collection_dir.close(io);
        var record_dir = try collection_dir.openDir(io, rid, .{ .follow_symlinks = false });
        errdefer record_dir.close(io);
        const stat = try record_dir.statFile(io, name, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.UnknownLayout;
        return .{ .dir = record_dir, .name = name, .stat = stat };
    }
    fn close(self: File, io: std.Io) void {
        self.dir.close(io);
    }
};

/// Refuse metadata that cannot establish physical references conservatively.
fn reference(alloc: std.mem.Allocator, conn: *db.Db, key: []const u8) inventory.Reference {
    return inventory.reconciliationReference(alloc, conn, key);
}

fn oldEnough(stat: std.Io.File.Stat, now: i64, minimum: u32) bool {
    // Wide subtraction tolerates future timestamps and extreme operator clocks.
    return @as(i128, now) * std.time.ns_per_s - stat.mtime.nanoseconds >= @as(i128, minimum) * std.time.ns_per_s;
}

fn unchanged(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == b.kind and a.inode == b.inode and a.size == b.size and
        a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}

/// Self-freeing. The caller holds the exclusive maintenance lease and writer
/// transaction; current references are checked again immediately before unlink.
fn removeCandidate(alloc: std.mem.Allocator, io: std.Io, conn: *db.Db, root: std.Io.Dir, key: []const u8, observed: std.Io.File.Stat, now: i64, minimum: u32) !Outcome {
    if (!conn.inTransaction()) return error.ReconciliationRequiresTransaction;
    const current = try File.open(io, root, key);
    defer current.close(io);
    if (!unchanged(observed, current.stat)) return .changed;
    if (!oldEnough(current.stat, now, minimum)) return .recent;
    switch (reference(alloc, conn, key)) {
        .referenced => return .referenced,
        .unknown => return .unknown,
        .candidate_unreferenced => {},
    }
    try current.dir.deleteFile(io, current.name);
    return .deleted;
}

/// Owned output; keys are borrowed only during rendering. At most one inventory
/// page is examined; failed/unknown checks never become deletion candidates.
pub fn run(alloc: std.mem.Allocator, io: std.Io, conn: *db.Db, root: std.Io.Dir, page: storage.Storage.InventoryPage, now: i64, minimum: u32, apply: bool) !Result {
    if (minimum == 0 or minimum > 31536000 or page.items.len > 1000) return error.InvalidReconciliationBounds;
    if (apply and (!conn.inTransaction() or db.dbDialect(conn).kind != .sqlite)) return error.ReconciliationRequiresTransaction;
    // Validate the entire report vocabulary before any unlink. A later bad key
    // or cursor must not turn earlier deletion into an unreportable partial run.
    if (page.nextCursor) |cursor| if (!std.unicode.utf8ValidateSlice(cursor)) return error.InvalidInventoryUtf8;
    for (page.items) |entry| if (!std.unicode.utf8ValidateSlice(entry.key)) return error.InvalidInventoryUtf8;
    const items = try alloc.alloc(Item, page.items.len);
    defer alloc.free(items);
    var failures: usize = 0;
    for (page.items, 0..) |entry, i| {
        items[i] = .{ .key = entry.key, .bytes = entry.bytes, .outcome = .unknown };
        const file = File.open(io, root, entry.key) catch |err| {
            if (err == error.FileNotFound) items[i].outcome = .missing else if (err != error.UnknownLayout and err != error.SymLinkLoop and err != error.NotDir) {
                failures += 1;
                items[i].outcome = .failed;
                items[i].failure = @errorName(err);
            }
            continue;
        };
        defer file.close(io);
        items[i].bytes = file.stat.size;
        items[i].modifiedAt = file.stat.mtime.toSeconds();
        const ref = reference(alloc, conn, entry.key);
        items[i].outcome = switch (ref) {
            .referenced => .referenced,
            .unknown => .unknown,
            .candidate_unreferenced => if (oldEnough(file.stat, now, minimum)) .candidate else .recent,
        };
        if (apply and items[i].outcome == .candidate) {
            items[i].outcome = removeCandidate(alloc, io, conn, root, entry.key, file.stat, now, minimum) catch |err| blk: {
                if (err == error.FileNotFound) break :blk .missing;
                failures += 1;
                items[i].failure = @errorName(err);
                break :blk .failed;
            };
        }
    }
    return .{ .failures = failures, .output = try std.json.Stringify.valueAlloc(alloc, .{
        .version = 1,
        .mode = if (apply) "apply" else "dry-run",
        .backend = "local-sqlite",
        .items = items,
        .nextCursor = page.nextCursor,
        .hasNext = page.nextCursor != null,
        .minAgeSeconds = minimum,
        .failures = failures,
        .warning = "Age alone is not safety. Apply requires stopped old/external writers and a dedicated storage root; deletions are irreversible and not transactional.",
    }, .{}) };
}

test "revalidation keeps newly reused references, changed objects, future timestamps and unknown schemas" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var conn = try db.Db.open(":memory:");
    defer conn.close();
    try @import("../migrations.zig").run(&conn);
    const col = try collections.create(a, io, &conn, .{
        .id = "",
        .name = "photos",
        .fields = &.{.{ .id = "file", .name = "file", .hidden = true, .options = .{ .file = .{} } }},
    });
    defer col.deinit(a);
    try tmp.dir.createDirPath(io, "photos/r1");
    try tmp.dir.writeFile(io, .{ .sub_path = "photos/r1/a.txt", .data = "old" });
    const initial = try File.open(io, tmp.dir, "photos/r1/a.txt");
    defer initial.close(io);
    const now = initial.stat.mtime.toSeconds() + 100;
    try std.testing.expect(!oldEnough(initial.stat, now - 200, 1));
    try std.testing.expect(!oldEnough(initial.stat, now, 101));
    try std.testing.expect(oldEnough(initial.stat, now, 99));
    try std.testing.expectEqual(inventory.Reference.unknown, reference(a, &conn, "absent/r1/a.txt"));
    try std.testing.expectError(error.ReconciliationRequiresTransaction, removeCandidate(a, io, &conn, tmp.dir, "photos/r1/a.txt", initial.stat, now, 1));
    try conn.beginImmediate();
    defer if (conn.inTransaction()) conn.rollback() catch unreachable;
    // The dry-run candidate is reused before deletion: fresh physical lookup wins.
    try conn.exec("INSERT INTO photos(id,created,updated,file) VALUES('r1','','','a.txt');");
    try std.testing.expectEqual(Outcome.referenced, try removeCandidate(a, io, &conn, tmp.dir, "photos/r1/a.txt", initial.stat, now, 1));
    try conn.exec("DELETE FROM photos;");
    try tmp.dir.writeFile(io, .{ .sub_path = "photos/r1/a.txt", .data = "replacement bytes" });
    try std.testing.expectEqual(Outcome.changed, try removeCandidate(a, io, &conn, tmp.dir, "photos/r1/a.txt", initial.stat, now, 1));
    const replacement = try File.open(io, tmp.dir, "photos/r1/a.txt");
    defer replacement.close(io);
    try std.testing.expectEqual(Outcome.deleted, try removeCandidate(a, io, &conn, tmp.dir, "photos/r1/a.txt", replacement.stat, now, 1));
    try std.testing.expectError(error.FileNotFound, File.open(io, tmp.dir, "photos/r1/a.txt"));
}

test "unknown paths, malformed metadata and out-of-bound pages cannot authorize deletion" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var conn = try db.Db.open(":memory:");
    defer conn.close();
    try std.testing.expectEqual(inventory.Reference.unknown, reference(a, &conn, "photos/r/a"));
    try std.testing.expectError(error.UnknownLayout, File.open(io, tmp.dir, "../r/a"));
    try std.testing.expectError(error.UnknownLayout, File.open(io, tmp.dir, "photos/r/a/child"));
    try tmp.dir.symLink(io, "/etc", "escape", .{ .is_directory = true });
    if (File.open(io, tmp.dir, "escape/r/a")) |file| {
        file.close(io);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expect(err == error.SymLinkLoop or err == error.NotDir);
    const page = storage.Storage.InventoryPage{ .items = &.{} };
    try std.testing.expectError(error.InvalidReconciliationBounds, run(a, io, &conn, tmp.dir, page, 0, 0, false));
    try std.testing.expectError(error.InvalidReconciliationBounds, run(a, io, &conn, tmp.dir, page, 0, 31536001, false));
}

test "invalid later keys and cursors are rejected before deleting a valid candidate" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var conn = try db.Db.open(":memory:");
    defer conn.close();
    try @import("../migrations.zig").run(&conn);
    const col = try collections.create(a, io, &conn, .{ .id = "", .name = "photos", .fields = &.{} });
    defer col.deinit(a);
    try tmp.dir.createDirPath(io, "photos/r1");
    try tmp.dir.writeFile(io, .{ .sub_path = "photos/r1/a.txt", .data = "keep" });
    const initial = try File.open(io, tmp.dir, "photos/r1/a.txt");
    defer initial.close(io);
    var entries = [_]storage.Storage.InventoryItem{
        .{ .key = "photos/r1/a.txt", .bytes = 4 },
        .{ .key = "photos/r1/\xff", .bytes = 4 },
    };
    try conn.beginImmediate();
    defer conn.rollback() catch unreachable;
    for ([_]storage.Storage.InventoryPage{
        .{ .items = &entries },
        .{ .items = entries[0..1], .nextCursor = "\xff" },
    }) |page| {
        try std.testing.expectError(error.InvalidInventoryUtf8, run(a, io, &conn, tmp.dir, page, initial.stat.mtime.toSeconds() + 100, 1, true));
        const retained = try File.open(io, tmp.dir, "photos/r1/a.txt");
        retained.close(io);
    }
    // Positive control: the retained first item really is deletable once the
    // entire report vocabulary is valid, not merely unknown metadata.
    const result = try run(a, io, &conn, tmp.dir, .{ .items = entries[0..1] }, initial.stat.mtime.toSeconds() + 100, 1, true);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), result.failures);
    try std.testing.expectError(error.FileNotFound, File.open(io, tmp.dir, "photos/r1/a.txt"));
}
