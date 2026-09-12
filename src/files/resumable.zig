//! Bounded RAM upload sessions, optionally mirrored to SQLite for process restart.
//! All metadata and payloads are owned by Store; leases pin a committing slot.
const std = @import("std");
const durable_enabled = @import("build_options").durable_resumable_uploads;

pub const Limits = @import("config.zig").ResumableLimits;

pub const State = enum { receiving, committing, completed, failed };
pub const Binding = struct {
    collection: []const u8,
    principal: []const u8,
    collection_id: if (durable_enabled) []const u8 else void = if (durable_enabled) "" else {},
    pub fn eql(a: Binding, b: Binding) bool {
        return std.mem.eql(u8, a.collection, b.collection) and std.mem.eql(u8, a.principal, b.principal) and (if (comptime durable_enabled) std.mem.eql(u8, a.collection_id, b.collection_id) else true);
    }
};
pub const Target = struct { collection: []const u8, collection_id: []const u8, record: []const u8, field: []const u8, filename: []const u8, mimetype: []const u8 };
pub const Status = struct { id: [32]u8, offset: usize, length: usize, expiresAt: i64, state: State, durability: []const u8 = "process-local" };
pub const Session = struct {
    status: Status,
    binding: Binding,
    target: Target,
    metadata: []u8,
    bytes: []u8,
};
pub const Error = error{ NotFound, Conflict, LimitExceeded, InvalidLength } || std.mem.Allocator.Error ||
    (if (durable_enabled) error{PersistenceFailed} else error{});

test "durability gates the public upload error contract" {
    const expected = error{ NotFound, Conflict, LimitExceeded, InvalidLength, OutOfMemory } ||
        (if (durable_enabled) error{PersistenceFailed} else error{});
    comptime if (Error != expected) @compileError("Upload errors must exclude disabled durable failures");
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    slots: []?Session,
    limits: Limits,
    allocated_bytes: usize = 0,
    durable: if (durable_enabled) ?@import("resumable_durable.zig").Durable else void = if (durable_enabled) null else {},
    poisoned: if (durable_enabled) bool else void = if (durable_enabled) false else {},

    pub fn enableDurability(self: *Store, pool: *@import("../db.zig").Pool, io: std.Io, now: i64) !void {
        self.durable = try @import("resumable_durable.zig").Durable.open(self.allocator, pool, io, self, now);
    }

    fn persistenceFailure(self: *Store, err: anyerror) Error {
        self.poison(err);
        return error.PersistenceFailed;
    }
    fn poison(self: *Store, err: anyerror) void {
        self.poisoned = true;
        std.log.err("durable uploads stopped until restart after persistence failure: {s}", .{@errorName(err)});
    }

    pub fn create(allocator: std.mem.Allocator, io: std.Io, limits: Limits) !*Store {
        const self = try allocator.create(Store);
        errdefer allocator.destroy(self);
        self.* = try init(allocator, io, limits);
        return self;
    }
    pub fn init(allocator: std.mem.Allocator, io: std.Io, limits: Limits) !Store {
        const slots = try allocator.alloc(?Session, limits.max_sessions);
        @memset(slots, null);
        return .{ .allocator = allocator, .io = io, .slots = slots, .limits = limits };
    }
    /// Owner must join all HTTP users before destruction; a mutex is not a lifetime guard.
    pub fn destroy(self: *Store) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }
    pub fn deinit(self: *Store) void {
        for (self.slots) |*slot| self.release(slot);
        self.allocator.free(self.slots);
        if (comptime durable_enabled) if (self.durable) |*durable| durable.close();
    }
    fn lock(self: *Store) void {
        // Persistence may wait for the writer and disk while holding this lock.
        // Park through the caller's Io instead of burning CPU on contention.
        self.mutex.lockUncancelable(self.io);
    }
    fn release(self: *Store, slot: *?Session) void {
        if (slot.*) |s| {
            self.allocated_bytes -= s.bytes.len;
            self.allocator.free(s.bytes);
            self.allocator.free(s.metadata);
            slot.* = null;
        }
    }
    fn expire(self: *Store, now: i64) Error!void {
        if (comptime durable_enabled) if (self.poisoned) return error.PersistenceFailed;
        // Bounded configured-slot sweep on every operation. Committing slots
        // remain pinned even across expiry until finish releases their payload.
        for (self.slots) |*slot| if (slot.*) |s| {
            if (s.status.state != .committing and s.status.expiresAt <= now) {
                if (comptime durable_enabled) if (self.durable) |*durable| durable.remove(&s.status.id) catch |err| return self.persistenceFailure(err);
                self.release(slot);
            }
        };
    }
    fn find(self: *Store, id: []const u8, binding: Binding) Error!*Session {
        for (self.slots) |*slot| if (slot.*) |*s| {
            if (std.mem.eql(u8, &s.status.id, id) and s.binding.eql(binding)) return s;
        };
        return error.NotFound;
    }
    pub fn begin(self: *Store, now: i64, binding: Binding, destination: Target, length: usize) Error!Status {
        if (length == 0 or length > self.limits.max_upload_bytes) return error.InvalidLength;
        const expires = std.math.add(i64, now, self.limits.ttl_seconds) catch return error.InvalidLength;
        if (comptime durable_enabled) if (self.durable != null and binding.collection_id.len == 0) return error.InvalidLength;
        const parts = [_][]const u8{ binding.collection, binding.principal, destination.collection, destination.collection_id, destination.record, destination.field, destination.filename, destination.mimetype, if (comptime durable_enabled) binding.collection_id else "" };
        var metadata_length: usize = 0;
        for (parts, 0..) |p, i| {
            if ((p.len == 0 and i != 8) or p.len > 255) return error.InvalidLength;
            metadata_length += p.len;
        }
        self.lock();
        defer self.mutex.unlock(self.io);
        try self.expire(now);
        var free: ?*?Session = null;
        var owned: usize = 0;
        for (self.slots) |*slot| {
            if (slot.*) |s| {
                if (s.binding.eql(binding)) owned += 1;
            } else if (free == null) free = slot;
        }
        if (owned >= self.limits.max_sessions_per_principal or free == null or length > self.limits.max_total_bytes - self.allocated_bytes) return error.LimitExceeded;
        const metadata = try self.allocator.alloc(u8, metadata_length);
        errdefer self.allocator.free(metadata);
        const bytes = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(bytes);
        var strings: [parts.len][]const u8 = undefined;
        var position: usize = 0;
        for (parts, 0..) |p, i| {
            @memcpy(metadata[position..][0..p.len], p);
            strings[i] = metadata[position..][0..p.len];
            position += p.len;
        }
        const id = id: for (0..4) |_| {
            var random: [16]u8 = undefined;
            self.io.random(&random); // OS entropy, never the deterministic development ID seam.
            const candidate = std.fmt.bytesToHex(random, .lower);
            for (self.slots) |slot| {
                if (slot) |s| if (std.mem.eql(u8, &candidate, &s.status.id)) break;
            } else break :id candidate;
        } else return error.LimitExceeded;
        var result = Status{ .id = id, .offset = 0, .length = length, .expiresAt = expires, .state = .receiving };
        if (comptime durable_enabled) if (self.durable != null) {
            result.durability = "sqlite-restart";
        };
        const session = Session{ .status = result, .metadata = metadata, .bytes = bytes, .binding = .{ .collection = strings[0], .principal = strings[1], .collection_id = if (comptime durable_enabled) strings[8] else {} }, .target = .{ .collection = strings[2], .collection_id = strings[3], .record = strings[4], .field = strings[5], .filename = strings[6], .mimetype = strings[7] } };
        if (comptime durable_enabled) if (self.durable) |*durable| durable.begin(self.allocator, session) catch |err| return self.persistenceFailure(err);
        free.?.* = session;
        self.allocated_bytes += length;
        return result;
    }
    pub fn status(self: *Store, now: i64, id: []const u8, binding: Binding) Error!Status {
        self.lock();
        defer self.mutex.unlock(self.io);
        try self.expire(now);
        return (try self.find(id, binding)).status;
    }
    pub fn append(self: *Store, now: i64, id: []const u8, binding: Binding, offset: usize, chunk: []const u8) Error!void {
        if (chunk.len == 0 or chunk.len > self.limits.max_chunk_bytes) return error.InvalidLength;
        self.lock();
        defer self.mutex.unlock(self.io);
        try self.expire(now);
        const s = try self.find(id, binding);
        if (s.status.state != .receiving or offset > s.status.offset or offset > s.bytes.len or chunk.len > s.bytes.len - offset) return error.Conflict;
        if (offset < s.status.offset) {
            // Only wholly acknowledged identical ranges are retries. A partial
            // overlap is never silently extended or interpreted as a new chunk.
            if (chunk.len > s.status.offset - offset or !std.mem.eql(u8, s.bytes[offset..][0..chunk.len], chunk)) return error.Conflict;
            return;
        }
        if (comptime durable_enabled) if (self.durable) |*durable| durable.append(id, offset, chunk) catch |err| return self.persistenceFailure(err);
        @memcpy(s.bytes[offset..][0..chunk.len], chunk);
        s.status.offset += chunk.len;
    }
    pub fn abort(self: *Store, now: i64, id: []const u8, binding: Binding) Error!void {
        self.lock();
        defer self.mutex.unlock(self.io);
        try self.expire(now);
        const s = try self.find(id, binding);
        // Cancellation only applies before commit. Keep terminal tombstones so
        // a lost commit response cannot be mistaken for a cancelled mutation.
        if (s.status.state != .receiving) return error.Conflict;
        if (comptime durable_enabled) if (self.durable) |*durable| durable.remove(id) catch |err| return self.persistenceFailure(err);
        for (self.slots) |*slot| if (slot.*) |*candidate| {
            if (candidate == s) {
                self.release(slot);
                return;
            }
        };
        unreachable; // find returns a member of slots under this same lock.
    }
    /// A non-null result is borrowed and pinned until finish. Persisting the
    /// transition holds the lock; the caller's storage/record mutation does not.
    pub fn commit(self: *Store, now: i64, id: []const u8, binding: Binding) Error!?*Session {
        self.lock();
        defer self.mutex.unlock(self.io);
        try self.expire(now);
        const s = try self.find(id, binding);
        if (s.status.state == .completed) return null;
        if (s.status.state != .receiving or s.status.offset != s.status.length) return error.Conflict;
        if (comptime durable_enabled) if (self.durable) |*durable| durable.transition(id, .committing) catch |err| return self.persistenceFailure(err);
        s.status.state = .committing;
        return s;
    }
    /// Every attempted commit is terminal, including pre-commit failures. This
    /// prevents a capability from repeating hooks or indeterminate storage work.
    pub fn finish(self: *Store, s: *Session, committed: bool) void {
        self.lock();
        defer self.mutex.unlock(self.io);
        std.debug.assert(s.status.state == .committing);
        // Completed was written atomically by records.updateResumable. Never
        // overwrite that receipt if a caller saw an uncertain commit error.
        if (comptime durable_enabled) if (self.durable) |*durable| {
            if (!committed) durable.failIfCommitting(&s.status.id) catch |err| {
                self.poison(err);
            };
        };
        self.allocated_bytes -= s.bytes.len;
        self.allocator.free(s.bytes);
        s.bytes = &.{};
        s.status.state = if (committed) .completed else .failed;
    }
};

const owner = Binding{ .collection = "users", .principal = "alice" };
const target = Target{ .collection = "posts", .collection_id = "collectionid", .record = "row", .field = "file", .filename = "a.txt", .mimetype = "text/plain" };
test "durable-only metadata and state vanish from RAM-only builds" {
    if (comptime !durable_enabled) {
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(@FieldType(Binding, "collection_id")));
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(@FieldType(Store, "durable")));
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(@FieldType(Store, "poisoned")));
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(@FieldType(Limits, "durable")));
        const Commit = @import("../api/records.zig").ResumableCommit;
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(@FieldType(Commit, "durable_id")));
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(@FieldType(Commit, "auth_collection_id")));
    }
}
test "resume offsets, principal binding, terminal commit and expiry" {
    var store = try Store.init(std.testing.allocator, std.testing.io, .{});
    defer store.deinit();
    const s = try store.begin(10, owner, target, 4);
    try std.testing.expectError(error.NotFound, store.status(10, &s.id, .{ .collection = "other", .principal = "alice" }));
    try store.append(10, &s.id, owner, 0, "ab");
    try store.append(10, &s.id, owner, 0, "ab");
    try std.testing.expectError(error.Conflict, store.append(10, &s.id, owner, 0, "zz"));
    try std.testing.expectError(error.Conflict, store.append(10, &s.id, owner, 1, "bc"));
    try std.testing.expectError(error.Conflict, store.append(10, &s.id, owner, 3, "d"));
    try store.append(10, &s.id, owner, 2, "cd");
    const lease = (try store.commit(10, &s.id, owner)).?;
    try std.testing.expectError(error.Conflict, store.abort(10, &s.id, owner));
    try std.testing.expectError(error.Conflict, store.commit(10, &s.id, owner));
    store.finish(lease, true);
    try std.testing.expectEqual(@as(usize, 0), store.allocated_bytes);
    try std.testing.expectError(error.Conflict, store.abort(10, &s.id, owner));
    try std.testing.expectEqual(State.completed, (try store.status(10, &s.id, owner)).state);
    try std.testing.expect(try store.commit(10, &s.id, owner) == null);
    try std.testing.expectError(error.NotFound, store.status(10 + store.limits.ttl_seconds, &s.id, owner));
}
test "session bounds, abort, failed terminal state and allocation cleanup" {
    var store = try Store.init(std.testing.allocator, std.testing.io, .{});
    defer store.deinit();
    const s = try store.begin(0, owner, target, 1);
    const receiving = try store.begin(0, owner, target, 1);
    try std.testing.expectError(error.LimitExceeded, store.begin(0, owner, target, 1));
    try store.append(0, &s.id, owner, 0, "x");
    const lease = (try store.commit(0, &s.id, owner)).?;
    store.finish(lease, false);
    try std.testing.expectError(error.Conflict, store.commit(0, &s.id, owner));
    try std.testing.expectError(error.Conflict, store.abort(0, &s.id, owner));
    try std.testing.expectEqual(State.failed, (try store.status(0, &s.id, owner)).state);
    try std.testing.expectError(error.LimitExceeded, store.begin(0, owner, target, 1));
    try std.testing.expectEqual(@as(usize, 1), store.allocated_bytes);
    try store.abort(0, &receiving.id, owner);
    try std.testing.expectError(error.NotFound, store.status(0, &receiving.id, owner));
    try std.testing.expectEqual(@as(usize, 0), store.allocated_bytes);
    _ = try store.begin(store.limits.ttl_seconds, owner, target, 1);
    try std.testing.expectEqual(@as(usize, 1), store.allocated_bytes);
}

test "aggregate payload and slot limits include tombstones but free bytes" {
    var store = try Store.init(std.testing.allocator, std.testing.io, .{ .max_sessions = 2, .max_sessions_per_principal = 2, .max_total_bytes = 4, .max_upload_bytes = 4, .max_chunk_bytes = 4 });
    defer store.deinit();
    const first = try store.begin(0, owner, target, 4);
    try std.testing.expectError(error.LimitExceeded, store.begin(0, owner, target, 1));
    try store.append(0, &first.id, owner, 0, "abcd");
    const pinned = (try store.commit(0, &first.id, owner)).?;
    // Expiry cannot free a borrowed committing payload.
    try std.testing.expectEqual(State.committing, (try store.status(10000, &first.id, owner)).state);
    try std.testing.expectEqualStrings("abcd", pinned.bytes);
    store.finish(pinned, true);
    const next = try store.begin(1, owner, target, 4);
    try store.append(1, &next.id, owner, 0, "efgh");
    store.finish((try store.commit(1, &next.id, owner)).?, false);
    try std.testing.expectEqual(@as(usize, 0), store.allocated_bytes);
    try std.testing.expectError(error.LimitExceeded, store.begin(1, .{ .collection = "users", .principal = "bob" }, target, 1));
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var store = try Store.init(allocator, std.testing.io, .{});
    defer store.deinit();
    _ = try store.begin(0, owner, target, 4);
}
test "partial store and session allocation failures release ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
    var store = try Store.init(std.testing.allocator, std.testing.io, .{});
    defer store.deinit();
    try std.testing.expectError(error.InvalidLength, store.begin(std.math.maxInt(i64), owner, target, 1));
    try std.testing.expectEqual(@as(usize, 0), store.allocated_bytes);
}

test "durable restart allocation failures release restored graphs and ownership lock" {
    if (comptime !durable_enabled) return error.SkipZigTest;
    const db = @import("../db.zig");
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/uploads.db", .{dir}, 0);
    defer allocator.free(path);
    var pool = try db.Pool.init(allocator, std.testing.io, path);
    defer pool.deinit();
    const limits = Limits{ .durable = true, .max_sessions = 2, .max_upload_bytes = 4, .max_total_bytes = 4, .max_chunk_bytes = 4 };
    {
        var seed = try Store.init(allocator, std.testing.io, limits);
        defer seed.deinit();
        try seed.enableDurability(&pool, std.testing.io, 0);
        const bound = Binding{ .collection = "users", .principal = "alice", .collection_id = "authid" };
        const session = try seed.begin(0, bound, target, 4);
        try seed.append(0, &session.id, bound, 0, "ab");
    }
    const Probe = struct {
        fn restore(a: std.mem.Allocator, p: *db.Pool) !void {
            var restored = try Store.init(a, std.testing.io, limits);
            defer restored.deinit();
            try restored.enableDurability(p, std.testing.io, 1);
            try std.testing.expectEqual(@as(usize, 2), restored.slots[0].?.status.offset);
            try std.testing.expectEqualStrings("ab", restored.slots[0].?.bytes[0..2]);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Probe.restore, .{&pool});
}

test "expired durable payloads are validated without allocating their bytes" {
    if (comptime !durable_enabled) return error.SkipZigTest;
    const db = @import("../db.zig");
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/uploads.db", .{dir}, 0);
    defer allocator.free(path);
    var pool = try db.Pool.init(allocator, std.testing.io, path);
    defer pool.deinit();
    const limits = Limits{ .durable = true, .max_upload_bytes = 65536, .max_total_bytes = 65536, .max_chunk_bytes = 4 };
    {
        var seed = try Store.init(allocator, std.testing.io, limits);
        defer seed.deinit();
        try seed.enableDurability(&pool, std.testing.io, 0);
        _ = try seed.begin(0, .{ .collection = "users", .principal = "alice", .collection_id = "authid" }, target, 65536);
    }
    // Enough for bounded metadata/slots, but cannot hold the expired payload.
    var scratch: [32768]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var restored = try Store.init(fixed.allocator(), std.testing.io, limits);
    defer restored.deinit();
    try restored.enableDurability(&pool, std.testing.io, 1000);
    try std.testing.expectEqual(@as(usize, 0), restored.allocated_bytes);
    for (restored.slots) |slot| try std.testing.expect(slot == null);
}

test "durable recovery rejects session keys and counts before reading payloads" {
    if (comptime !durable_enabled) return error.SkipZigTest;
    const db = @import("../db.zig");
    const c = @import("../c.zig").c;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/uploads.db", .{dir}, 0);
    defer allocator.free(path);
    var pool = try db.Pool.init(allocator, std.testing.io, path);
    defer pool.deinit();
    const limits = Limits{ .durable = true, .max_sessions = 1, .max_sessions_per_principal = 1 };
    {
        var seed = try Store.init(allocator, std.testing.io, limits);
        defer seed.deinit();
        try seed.enableDurability(&pool, std.testing.io, 0);
    }
    const Probe = struct {
        fn callback(_: ?*anyopaque, action: c_int, table: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            if (action == c.SQLITE_READ and table != null and std.mem.eql(u8, std.mem.span(table), "_upload_payloads")) return c.SQLITE_DENY;
            return c.SQLITE_OK;
        }
    };
    for ([_][:0]const u8{
        "INSERT INTO _upload_sessions VALUES(CAST(zeroblob(1048576) AS TEXT),'{}',4,0,0,'receiving');",
        "INSERT INTO _upload_sessions VALUES(zeroblob(1048576),'{}',4,0,0,'receiving');",
        "INSERT INTO _upload_sessions VALUES(printf('%032d',1),'{}',4,0,0,'receiving'),(printf('%032d',2),'{}',4,0,0,'receiving');",
    }) |mutation| {
        const handle = blk: {
            const w = pool.acquireWriter();
            defer pool.releaseWriter();
            try w.exec("DELETE FROM _upload_sessions;");
            try w.exec(mutation);
            break :blk db.sqliteHandle(w);
        };
        // Any access to the payload table would fail with PrepareFailed. The
        // session-side preflight must reject corruption before reaching it.
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(handle, Probe.callback, null));
        defer std.debug.assert(c.sqlite3_set_authorizer(handle, null, null) == c.SQLITE_OK);
        var restored = try Store.init(allocator, std.testing.io, limits);
        defer restored.deinit();
        try std.testing.expectError(error.InvalidUploadStore, restored.enableDurability(&pool, std.testing.io, 1000));
        try std.testing.expectEqual(@as(usize, 0), restored.allocated_bytes);
    }
}

test "durable startup validates the runtime SQLite whole-row limit before persistence" {
    if (comptime !durable_enabled) return error.SkipZigTest;
    const db = @import("../db.zig");
    const c = @import("../c.zig").c;
    const config = @import("config.zig");
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/uploads.db", .{dir}, 0);
    defer allocator.free(path);
    var pool = try db.Pool.init(allocator, std.testing.io, path);
    defer pool.deinit();
    const limits = Limits{ .durable = true, .max_upload_bytes = 4, .max_total_bytes = 4, .max_chunk_bytes = 4 };
    var store = try Store.init(allocator, std.testing.io, limits);
    defer store.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        _ = c.sqlite3_limit(db.sqliteHandle(w), c.SQLITE_LIMIT_LENGTH, config.durable_row_overhead + 3);
        // The BLOB alone fits; the configured worst-case complete row does not.
    }
    try std.testing.expectError(error.DurableUploadRowLimit, store.enableDurability(&pool, std.testing.io, 0));
    try std.testing.expectEqual(@as(usize, 0), store.allocated_bytes);
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        var st = try w.prepare("SELECT 1 FROM sqlite_schema WHERE name='_upload_sessions';");
        defer st.finalize();
        try std.testing.expect(!try st.step());
        _ = c.sqlite3_limit(db.sqliteHandle(w), c.SQLITE_LIMIT_LENGTH, config.durable_row_overhead + 4);
    }
    try store.enableDurability(&pool, std.testing.io, 0);
    {
        var no_alloc = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        store.allocator = no_alloc.allocator();
        defer store.allocator = allocator;
        try std.testing.expectError(error.InvalidLength, store.begin(0, owner, target, 4));
        try std.testing.expect(!no_alloc.has_induced_failure);
    }
    try std.testing.expectEqual(@as(usize, 0), store.allocated_bytes);
    try std.testing.expect(!store.poisoned);
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        var rows = try w.prepare("SELECT 1 FROM \"_upload_sessions\";");
        defer rows.finalize();
        try std.testing.expect(!try rows.step());
    }
    const bound = Binding{ .collection = "users", .principal = "alice", .collection_id = "authid" };
    const session = try store.begin(0, bound, target, 4);
    try store.append(0, &session.id, bound, 0, "abcd");
    try std.testing.expectEqual(@as(usize, 4), (try store.status(0, &session.id, bound)).offset);
}

test "durable writes release transactions after commit failure" {
    if (comptime !durable_enabled) return error.SkipZigTest;
    const db = @import("../db.zig");
    const c = @import("../c.zig").c;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/uploads.db", .{dir}, 0);
    defer allocator.free(path);
    var pool = try db.Pool.init(allocator, std.testing.io, path);
    defer pool.deinit();
    var store = try Store.init(allocator, std.testing.io, .{ .durable = true });
    defer store.deinit();
    try store.enableDurability(&pool, std.testing.io, 0);
    const bound = Binding{ .collection = "users", .principal = "alice", .collection_id = "authid" };
    const session = try store.begin(0, bound, target, 4);
    try store.append(0, &session.id, bound, 0, "abcd");
    const Failure = struct {
        fn abortCommit(_: ?*anyopaque) callconv(.c) c_int {
            return 1;
        }
    };
    const durable = &store.durable.?;
    for (0..3) |operation| {
        if (operation == 2) try durable.transition(&session.id, .committing);
        const handle = blk: {
            const w = pool.acquireWriter();
            defer pool.releaseWriter();
            break :blk db.sqliteHandle(w);
        };
        _ = c.sqlite3_commit_hook(handle, Failure.abortCommit, null);
        {
            defer _ = c.sqlite3_commit_hook(handle, null, null);
            // Statements and transaction cleanup finish before releasing the
            // writer, including SQLite's automatic rollback on commit failure.
            try std.testing.expectError(error.ExecFailed, switch (operation) {
                0 => durable.remove(&session.id),
                1 => durable.transition(&session.id, .committing),
                else => durable.failIfCommitting(&session.id),
            });
        }
        {
            const w = pool.acquireWriter();
            defer pool.releaseWriter();
            try std.testing.expect(!w.inTransaction());
            try std.testing.expectEqual(c.SQLITE_TXN_NONE, c.sqlite3_txn_state(db.sqliteHandle(w), "main"));
            try w.exec("CREATE TABLE IF NOT EXISTS unrelated_write(value INTEGER); INSERT INTO unrelated_write VALUES(1);");
        }
        var reader = try pool.acquireReader();
        defer pool.releaseReader(&reader);
        var receipt = try reader.prepare("SELECT state,offset,coalesce(length(payload),0) FROM _upload_sessions s LEFT JOIN _upload_payloads p ON p.session=s.id WHERE s.id=?;");
        defer receipt.finalize();
        try receipt.bindText(1, &session.id);
        try std.testing.expect(try receipt.step());
        try std.testing.expectEqualStrings(if (operation == 2) "committing" else "receiving", receipt.columnText(0));
        try std.testing.expectEqual(@as(i64, 4), receipt.columnInt(1));
        try std.testing.expectEqual(@as(i64, 4), receipt.columnInt(2));
    }
    // Cleanup remains atomic even if custom migration code disabled FK checks.
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try w.exec("PRAGMA foreign_keys=OFF;");
    }
    try durable.remove(&session.id);
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        var remaining = try w.prepare("SELECT (SELECT count(*) FROM _upload_sessions)+(SELECT count(*) FROM _upload_payloads);");
        defer remaining.finalize();
        try std.testing.expect(try remaining.step());
        try std.testing.expectEqual(@as(i64, 0), remaining.columnInt(0));
    }
}

test "durable contention parks and acknowledges only persisted session offsets" {
    if (comptime !durable_enabled) return error.SkipZigTest;
    const db = @import("../db.zig");
    const Probe = struct {
        const Self = @This();
        threadlocal var active: ?*@This() = null;
        store: *Store,
        writer_waiting: std.Io.Event = .unset,
        store_waiting: std.Io.Event = .unset,

        fn wait(raw: ?*anyopaque, ptr: *const u32, expected: u32) void {
            if (active) |self| {
                if (@intFromPtr(ptr) == @intFromPtr(&self.store.mutex.state.raw)) {
                    self.store_waiting.set(std.testing.io);
                } else {
                    self.writer_waiting.set(std.testing.io);
                }
            }
            // Observe actual parking, not a substitute lock or scheduler delay.
            std.testing.io.vtable.futexWaitUncancelable(raw, ptr, expected);
        }
        const Worker = struct {
            probe: *Self,
            id: [32]u8,
            failure: ?Error = null,
            done: std.Io.Event = .unset,
            fn run(self: *@This()) void {
                active = self.probe;
                defer active = null;
                self.probe.store.append(1, &self.id, .{ .collection = "users", .principal = "alice", .collection_id = "authid" }, 0, "ab") catch |err| {
                    self.failure = err;
                };
                self.done.set(std.testing.io);
            }
        };
    };
    var vtable = std.testing.io.vtable.*;
    vtable.futexWaitUncancelable = Probe.wait;
    const io = std.Io{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/contention.db", .{dir}, 0);
    defer std.testing.allocator.free(path);
    var pool = try db.Pool.init(std.testing.allocator, io, path);
    defer pool.deinit();
    var store = try Store.init(std.testing.allocator, io, .{ .durable = true });
    defer store.deinit();
    try store.enableDurability(&pool, io, 0);
    const binding = Binding{ .collection = "users", .principal = "alice", .collection_id = "authid" };
    const first = try store.begin(0, binding, target, 4);
    const second = try store.begin(0, binding, target, 4);
    var probe = Probe{ .store = &store };
    var one = Probe.Worker{ .probe = &probe, .id = first.id };
    var two = Probe.Worker{ .probe = &probe, .id = second.id };
    _ = pool.acquireWriter();
    var held = true;
    var t1: ?std.Thread = null;
    var t2: ?std.Thread = null;
    defer {
        if (held) pool.releaseWriter();
        if (t1) |thread| thread.join();
        if (t2) |thread| thread.join();
    }
    t1 = try std.Thread.spawn(.{}, Probe.Worker.run, .{&one});
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };
    try probe.writer_waiting.waitTimeout(std.testing.io, timeout);
    t2 = try std.Thread.spawn(.{}, Probe.Worker.run, .{&two});
    try probe.store_waiting.waitTimeout(std.testing.io, timeout);
    try std.testing.expect(!one.done.isSet() and !two.done.isSet());
    // The writer cannot commit yet: no RAM offset or acknowledgement may advance.
    try std.testing.expectEqual(@as(usize, 0), store.slots[0].?.status.offset);
    try std.testing.expectEqual(@as(usize, 0), store.slots[1].?.status.offset);
    pool.releaseWriter();
    held = false;
    t1.?.join();
    t1 = null;
    t2.?.join();
    t2 = null;
    try std.testing.expectEqual(null, one.failure);
    try std.testing.expectEqual(null, two.failure);
    var reader = try pool.acquireReader();
    defer pool.releaseReader(&reader);
    var rows = try reader.prepare("SELECT offset,substr(payload,1,2) FROM _upload_sessions s JOIN _upload_payloads p ON p.session=s.id ORDER BY s.id;");
    defer rows.finalize();
    var count: usize = 0;
    while (try rows.step()) {
        count += 1;
        try std.testing.expectEqual(@as(i64, 2), rows.columnInt(0));
        try std.testing.expectEqualStrings("ab", rows.columnText(1));
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 2), (try store.status(1, &first.id, binding)).offset);
    try std.testing.expectEqual(@as(usize, 2), (try store.status(1, &second.id, binding)).offset);
}
