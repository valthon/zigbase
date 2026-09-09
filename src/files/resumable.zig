//! Bounded, process-local network resume. No disk staging or restart durability.
//! All metadata and payloads are owned by Store; leases pin a committing slot.
const std = @import("std");

pub const Limits = @import("config.zig").ResumableLimits;

pub const State = enum { receiving, committing, completed, failed };
pub const Binding = struct {
    collection: []const u8,
    principal: []const u8,
    pub fn eql(a: Binding, b: Binding) bool {
        return std.mem.eql(u8, a.collection, b.collection) and std.mem.eql(u8, a.principal, b.principal);
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
pub const Error = error{ NotFound, Conflict, LimitExceeded, InvalidLength } || std.mem.Allocator.Error;

pub const Store = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    slots: []?Session,
    limits: Limits,
    allocated_bytes: usize = 0,

    pub fn create(allocator: std.mem.Allocator, limits: Limits) !*Store {
        const self = try allocator.create(Store);
        errdefer allocator.destroy(self);
        self.* = try init(allocator, limits);
        return self;
    }
    pub fn init(allocator: std.mem.Allocator, limits: Limits) !Store {
        const slots = try allocator.alloc(?Session, limits.max_sessions);
        @memset(slots, null);
        return .{ .allocator = allocator, .slots = slots, .limits = limits };
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
    }
    fn lock(self: *Store) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn release(self: *Store, slot: *?Session) void {
        if (slot.*) |s| {
            self.allocated_bytes -= s.bytes.len;
            self.allocator.free(s.bytes);
            self.allocator.free(s.metadata);
            slot.* = null;
        }
    }
    fn expire(self: *Store, now: i64) void {
        // Bounded configured-slot sweep on every operation. Committing slots
        // remain pinned even across expiry until finish releases their payload.
        for (self.slots) |*slot| if (slot.*) |s| {
            if (s.status.state != .committing and s.status.expiresAt <= now) self.release(slot);
        };
    }
    fn find(self: *Store, id: []const u8, binding: Binding) Error!*Session {
        for (self.slots) |*slot| if (slot.*) |*s| {
            if (std.mem.eql(u8, &s.status.id, id) and s.binding.eql(binding)) return s;
        };
        return error.NotFound;
    }
    pub fn begin(self: *Store, io: std.Io, now: i64, binding: Binding, destination: Target, length: usize) Error!Status {
        if (length == 0 or length > self.limits.max_upload_bytes) return error.InvalidLength;
        const expires = std.math.add(i64, now, self.limits.ttl_seconds) catch return error.InvalidLength;
        const parts = [_][]const u8{ binding.collection, binding.principal, destination.collection, destination.collection_id, destination.record, destination.field, destination.filename, destination.mimetype };
        var metadata_length: usize = 0;
        for (parts) |p| {
            if (p.len == 0 or p.len > 255) return error.InvalidLength;
            metadata_length += p.len;
        }
        self.lock();
        defer self.mutex.unlock();
        self.expire(now);
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
            io.random(&random); // OS entropy, never the deterministic development ID seam.
            const candidate = std.fmt.bytesToHex(random, .lower);
            for (self.slots) |slot| {
                if (slot) |s| if (std.mem.eql(u8, &candidate, &s.status.id)) break;
            } else break :id candidate;
        } else return error.LimitExceeded;
        const result = Status{ .id = id, .offset = 0, .length = length, .expiresAt = expires, .state = .receiving };
        free.?.* = .{ .status = result, .metadata = metadata, .bytes = bytes, .binding = .{ .collection = strings[0], .principal = strings[1] }, .target = .{ .collection = strings[2], .collection_id = strings[3], .record = strings[4], .field = strings[5], .filename = strings[6], .mimetype = strings[7] } };
        self.allocated_bytes += length;
        return result;
    }
    pub fn status(self: *Store, now: i64, id: []const u8, binding: Binding) Error!Status {
        self.lock();
        defer self.mutex.unlock();
        self.expire(now);
        return (try self.find(id, binding)).status;
    }
    pub fn append(self: *Store, now: i64, id: []const u8, binding: Binding, offset: usize, chunk: []const u8) Error!void {
        if (chunk.len == 0 or chunk.len > self.limits.max_chunk_bytes) return error.InvalidLength;
        self.lock();
        defer self.mutex.unlock();
        self.expire(now);
        const s = try self.find(id, binding);
        if (s.status.state != .receiving or offset > s.status.offset or offset > s.bytes.len or chunk.len > s.bytes.len - offset) return error.Conflict;
        if (offset < s.status.offset) {
            // Only wholly acknowledged identical ranges are retries. A partial
            // overlap is never silently extended or interpreted as a new chunk.
            if (chunk.len > s.status.offset - offset or !std.mem.eql(u8, s.bytes[offset..][0..chunk.len], chunk)) return error.Conflict;
            return;
        }
        @memcpy(s.bytes[offset..][0..chunk.len], chunk);
        s.status.offset += chunk.len;
    }
    pub fn abort(self: *Store, now: i64, id: []const u8, binding: Binding) Error!void {
        self.lock();
        defer self.mutex.unlock();
        self.expire(now);
        const s = try self.find(id, binding);
        // Cancellation only applies before commit. Keep terminal tombstones so
        // a lost commit response cannot be mistaken for a cancelled mutation.
        if (s.status.state != .receiving) return error.Conflict;
        for (self.slots) |*slot| if (slot.*) |*candidate| {
            if (candidate == s) {
                self.release(slot);
                return;
            }
        };
        unreachable; // find returns a member of slots under this same lock.
    }
    /// A non-null result is borrowed and pinned until finish. No lock is held
    /// during storage or DB work; other sessions continue progressing normally.
    pub fn commit(self: *Store, now: i64, id: []const u8, binding: Binding) Error!?*Session {
        self.lock();
        defer self.mutex.unlock();
        self.expire(now);
        const s = try self.find(id, binding);
        if (s.status.state == .completed) return null;
        if (s.status.state != .receiving or s.status.offset != s.status.length) return error.Conflict;
        s.status.state = .committing;
        return s;
    }
    /// Every attempted commit is terminal, including pre-commit failures. This
    /// prevents a capability from repeating hooks or indeterminate storage work.
    pub fn finish(self: *Store, s: *Session, committed: bool) void {
        self.lock();
        defer self.mutex.unlock();
        std.debug.assert(s.status.state == .committing);
        self.allocated_bytes -= s.bytes.len;
        self.allocator.free(s.bytes);
        s.bytes = &.{};
        s.status.state = if (committed) .completed else .failed;
    }
};

const owner = Binding{ .collection = "users", .principal = "alice" };
const target = Target{ .collection = "posts", .collection_id = "collectionid", .record = "row", .field = "file", .filename = "a.txt", .mimetype = "text/plain" };
test "resume offsets, principal binding, terminal commit and expiry" {
    var store = try Store.init(std.testing.allocator, .{});
    defer store.deinit();
    const s = try store.begin(std.testing.io, 10, owner, target, 4);
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
    var store = try Store.init(std.testing.allocator, .{});
    defer store.deinit();
    const s = try store.begin(std.testing.io, 0, owner, target, 1);
    const receiving = try store.begin(std.testing.io, 0, owner, target, 1);
    try std.testing.expectError(error.LimitExceeded, store.begin(std.testing.io, 0, owner, target, 1));
    try store.append(0, &s.id, owner, 0, "x");
    const lease = (try store.commit(0, &s.id, owner)).?;
    store.finish(lease, false);
    try std.testing.expectError(error.Conflict, store.commit(0, &s.id, owner));
    try std.testing.expectError(error.Conflict, store.abort(0, &s.id, owner));
    try std.testing.expectEqual(State.failed, (try store.status(0, &s.id, owner)).state);
    try std.testing.expectError(error.LimitExceeded, store.begin(std.testing.io, 0, owner, target, 1));
    try std.testing.expectEqual(@as(usize, 1), store.allocated_bytes);
    try store.abort(0, &receiving.id, owner);
    try std.testing.expectError(error.NotFound, store.status(0, &receiving.id, owner));
    try std.testing.expectEqual(@as(usize, 0), store.allocated_bytes);
    _ = try store.begin(std.testing.io, store.limits.ttl_seconds, owner, target, 1);
    try std.testing.expectEqual(@as(usize, 1), store.allocated_bytes);
}

test "aggregate payload and slot limits include tombstones but free bytes" {
    var store = try Store.init(std.testing.allocator, .{ .max_sessions = 2, .max_sessions_per_principal = 2, .max_total_bytes = 4, .max_upload_bytes = 4, .max_chunk_bytes = 4 });
    defer store.deinit();
    const first = try store.begin(std.testing.io, 0, owner, target, 4);
    try std.testing.expectError(error.LimitExceeded, store.begin(std.testing.io, 0, owner, target, 1));
    try store.append(0, &first.id, owner, 0, "abcd");
    const pinned = (try store.commit(0, &first.id, owner)).?;
    // Expiry cannot free a borrowed committing payload.
    try std.testing.expectEqual(State.committing, (try store.status(10000, &first.id, owner)).state);
    try std.testing.expectEqualStrings("abcd", pinned.bytes);
    store.finish(pinned, true);
    const next = try store.begin(std.testing.io, 1, owner, target, 4);
    try store.append(1, &next.id, owner, 0, "efgh");
    store.finish((try store.commit(1, &next.id, owner)).?, false);
    try std.testing.expectEqual(@as(usize, 0), store.allocated_bytes);
    try std.testing.expectError(error.LimitExceeded, store.begin(std.testing.io, 1, .{ .collection = "users", .principal = "bob" }, target, 1));
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var store = try Store.init(allocator, .{});
    defer store.deinit();
    _ = try store.begin(std.testing.io, 0, owner, target, 4);
}
test "partial store and session allocation failures release ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
    var store = try Store.init(std.testing.allocator, .{});
    defer store.deinit();
    try std.testing.expectError(error.InvalidLength, store.begin(std.testing.io, std.math.maxInt(i64), owner, target, 1));
    try std.testing.expectEqual(@as(usize, 0), store.allocated_bytes);
}
