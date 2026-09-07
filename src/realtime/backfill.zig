//! Bounded, process-local invalidations. Never a durable event log.
const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
pub const max_topics = 16;
pub const max_entries = 256; // per topic
pub const max_bytes = 64 * 1024; // encoded frames per topic; 1 MiB total
pub const Entry = struct { sequence: u64, frame: []const u8 };
pub const Page = struct { items: []const Entry, generation: u64, next: u64, has_next: bool };

const Topic = struct {
    id: []const u8,
    generation: u64,
    used: u64,
    entries: [max_entries]Entry = undefined,
    first: usize = 0,
    count: usize = 0,
    bytes: usize = 0,
    sequence: u64 = 0,
    floor: u64 = 0,
    fn evict(self: *Topic, allocator: std.mem.Allocator) void {
        const e = self.entries[self.first];
        self.floor = e.sequence;
        self.bytes -= e.frame.len;
        allocator.free(e.frame);
        self.first = (self.first + 1) % max_entries;
        self.count -= 1;
    }
    fn clear(self: *Topic, allocator: std.mem.Allocator) void {
        while (self.count > 0) self.evict(allocator);
    }
    fn invalidate(self: *Topic, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.sequence += 1;
        self.floor = self.sequence;
    }
    fn appendOwned(self: *Topic, allocator: std.mem.Allocator, owned: []const u8) void {
        self.sequence += 1;
        while (self.count == max_entries or self.bytes + owned.len > max_bytes) self.evict(allocator);
        self.entries[(self.first + self.count) % max_entries] = .{ .sequence = self.sequence, .frame = owned };
        self.count += 1;
        self.bytes += owned.len;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    epoch: [32]u8,
    mutex: std.atomic.Mutex = .unlocked,
    // Lazy rings: idle enabled servers pay only for these pointers.
    topics: [max_topics]?*Topic = @splat(null),
    generation: u64 = 0,
    clock: u64 = 0,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, backend: @import("../db.zig").Backend) !?*Store {
        if (backend != .sqlite) return null;
        const store = try allocator.create(Store);
        store.* = init(allocator, io);
        return store;
    }
    /// Requires exclusive ownership: stop and join every capture/page user
    /// before destroying the store. A mutex cannot protect references after free.
    pub fn destroy(self: *Store) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Store {
        var entropy: [16]u8 = undefined;
        io.random(&entropy);
        return .{ .allocator = allocator, .epoch = std.fmt.bytesToHex(entropy, .lower) };
    }
    fn lock(self: *Store) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn freeTopic(self: *Store, topic: *Topic) void {
        topic.clear(self.allocator);
        self.allocator.free(topic.id);
        self.allocator.destroy(topic);
    }
    /// All users must already be stopped/joined. Framework teardown satisfies
    /// this after the HTTP reactor returns and scheduler/background workers join.
    pub fn deinit(self: *Store) void {
        for (&self.topics) |*slot| {
            if (slot.*) |topic| self.freeTopic(topic);
            slot.* = null;
        }
    }
    fn find(self: *Store, id: []const u8) ?*Topic {
        for (self.topics) |slot| {
            if (slot) |topic| {
                if (std.mem.eql(u8, topic.id, id)) return topic;
            }
        }
        return null;
    }
    fn touch(self: *Store, topic: *Topic) void {
        self.clock += 1;
        topic.used = self.clock;
    }
    /// Called under the lock. Bound both ring count and topic-id storage.
    /// Replace only after successful allocation; OOM cannot evict another topic.
    fn getOrCreate(self: *Store, id: []const u8, admission: enum { free_slot_only, replace_oldest }) !*Topic {
        if (self.find(id)) |topic| return topic;
        if (id.len > 256) return error.TopicTooLarge;
        var oldest: usize = 0;
        for (self.topics, 0..) |slot, i| {
            if (slot == null) {
                oldest = i;
                break;
            }
            if (slot.?.used < self.topics[oldest].?.used) oldest = i;
        }
        // A checkpoint-only read cannot discard another collection's history.
        // Check capacity before allocating, including on the OOM path.
        if (admission == .free_slot_only and self.topics[oldest] != null) return error.ResetRequired;
        const topic = try self.allocator.create(Topic);
        errdefer self.allocator.destroy(topic);
        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        if (self.topics[oldest]) |old| self.freeTopic(old);
        self.generation += 1;
        topic.* = .{ .id = owned_id, .generation = self.generation, .used = self.clock };
        self.topics[oldest] = topic;
        return topic;
    }
    /// Failed capture invalidates this topic only. An absent slot has no valid
    /// checkpoints; its next allocation gets a fresh generation.
    pub fn invalidate(self: *Store, id: []const u8) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.find(id)) |topic| {
            self.touch(topic);
            topic.invalidate(self.allocator);
        }
    }
    pub fn append(self: *Store, id: []const u8, frame: []const u8) !void {
        self.lock();
        defer self.mutex.unlock();
        errdefer if (self.find(id)) |topic| topic.invalidate(self.allocator);
        if (frame.len > max_bytes) return error.EventTooLarge;
        // Complete fallible payload work before replacing any slot. A failed
        // write must not evict another collection's valid checkpoint/history.
        const owned = try self.allocator.dupe(u8, frame);
        errdefer self.allocator.free(owned);
        const topic = try self.getOrCreate(id, .replace_oldest);
        self.touch(topic);
        topic.appendOwned(self.allocator, owned);
    }
    /// Arena-scoped graph: independent frame copies survive concurrent eviction.
    /// Limit counts this topic's entries before authorization, so denied pages progress.
    pub fn page(self: *Store, arena: RequestArena, id: []const u8, checkpoint: ?[]const u8, limit: usize) !Page {
        self.lock();
        defer self.mutex.unlock();
        if (limit == 0 or limit > 128) return error.BadLimit;
        const c = checkpoint orelse {
            const topic = try self.getOrCreate(id, .free_slot_only);
            self.touch(topic);
            return .{ .items = &.{}, .generation = topic.generation, .next = topic.sequence, .has_next = false };
        };
        if (c.len < 36 or c[32] != ':' or !std.mem.eql(u8, c[0..32], &self.epoch)) return error.ResetRequired;
        const separator = std.mem.indexOfScalarPos(u8, c, 33, ':') orelse return error.ResetRequired;
        const generation = std.fmt.parseInt(u64, c[33..separator], 10) catch return error.ResetRequired;
        const after = std.fmt.parseInt(u64, c[separator + 1 ..], 10) catch return error.ResetRequired;
        const topic = self.find(id) orelse return error.ResetRequired;
        if (generation != topic.generation or after < topic.floor or after > topic.sequence) return error.ResetRequired;
        self.touch(topic);
        var out: std.ArrayList(Entry) = .empty;
        var next = after;
        for (0..topic.count) |offset| {
            const e = topic.entries[(topic.first + offset) % max_entries];
            if (e.sequence <= after) continue;
            if (out.items.len == limit) break;
            try out.append(arena.a, .{ .sequence = e.sequence, .frame = try arena.a.dupe(u8, e.frame) });
            next = e.sequence;
        }
        return .{ .items = out.items, .generation = topic.generation, .next = next, .has_next = next < topic.sequence };
    }
    pub fn cursor(self: *const Store, allocator: std.mem.Allocator, page_result: Page) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{d}:{d}", .{ self.epoch, page_result.generation, page_result.next });
    }
};

test "quiet topic history and pagination survive hot topic eviction" {
    var store = Store.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = RequestArena{ .a = fba.allocator() };
    const checkpoint = try store.cursor(std.testing.allocator, try store.page(arena, "quiet", null, 1));
    defer std.testing.allocator.free(checkpoint);
    try store.append("quiet", "first");
    for (0..max_entries * 2) |_| try store.append("hot", "unrelated");
    const page1 = try store.page(arena, "quiet", checkpoint, 1);
    try std.testing.expect(!page1.has_next);
    try std.testing.expectEqual(@as(usize, 1), page1.items.len);
    try std.testing.expectEqualStrings("first", page1.items[0].frame);
    const next = try store.cursor(std.testing.allocator, page1);
    defer std.testing.allocator.free(next);
    for (0..max_entries * 2) |_| try store.append("hot", "unrelated");
    // Empty polls neither allocate nor paginate over unrelated frames.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const empty = try store.page(.{ .a = failing.allocator() }, "quiet", next, 1);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expect(!empty.has_next);
    try store.append("quiet", "second");
    try store.append("quiet", "third");
    const page2 = try store.page(arena, "quiet", next, 1);
    try std.testing.expect(page2.has_next);
    store.invalidate("quiet");
    try std.testing.expectError(error.ResetRequired, store.page(arena, "quiet", next, 1));
    try std.testing.expectEqualStrings("second", page2.items[0].frame);
}

test "topic slot replacement and process restart require reset" {
    var store = Store.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const arena = RequestArena{ .a = failing.allocator() };
    const checkpoint = try store.cursor(std.testing.allocator, try store.page(arena, "old", null, 1));
    defer std.testing.allocator.free(checkpoint);
    for (0..max_topics) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "topic{d}", .{i});
        try store.append(name, "{}");
    }
    try std.testing.expectError(error.ResetRequired, store.page(arena, "old", checkpoint, 1));
    try std.testing.expectError(error.ResetRequired, store.page(arena, "old", null, 1));
    // A write can replace a slot, but must not revive the old generation.
    try store.append("old", "{}");
    try std.testing.expectError(error.ResetRequired, store.page(arena, "old", checkpoint, 1));
    var restarted = Store.init(std.testing.allocator, std.testing.io);
    defer restarted.deinit();
    _ = try restarted.page(arena, "old", null, 1);
    try std.testing.expectError(error.ResetRequired, restarted.page(arena, "old", checkpoint, 1));
}

test "cursorless reads never displace occupied slots or allocate when full" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var store = Store.init(failing.allocator(), std.testing.io);
    defer store.deinit();
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = RequestArena{ .a = fba.allocator() };
    const checkpoint = try store.cursor(std.testing.allocator, try store.page(arena, "oldest", null, 1));
    defer std.testing.allocator.free(checkpoint);
    try store.append("oldest", "retained");
    for (0..max_topics - 1) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "topic{d}", .{i});
        _ = try store.page(arena, name, null, 1);
    }
    const generation = store.generation;
    failing.fail_index = failing.alloc_index;
    for (0..max_topics * 2) |_| {
        try std.testing.expectError(error.ResetRequired, store.page(arena, "untracked", null, 1));
    }
    try std.testing.expectEqual(generation, store.generation);
    const retained = try store.page(arena, "oldest", checkpoint, 1);
    try std.testing.expectEqualStrings("retained", retained.items[0].frame);
    _ = try store.page(arena, "oldest", null, 1); // existing slots need no allocation
}

test "eviction oversized events and allocation failure invalidate only their topic" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var store = Store.init(failing.allocator(), std.testing.io);
    defer store.deinit();
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = RequestArena{ .a = fba.allocator() };
    const quiet = try store.cursor(std.testing.allocator, try store.page(arena, "quiet", null, 1));
    defer std.testing.allocator.free(quiet);
    const initial = try store.cursor(std.testing.allocator, try store.page(arena, "posts", null, 1));
    defer std.testing.allocator.free(initial);
    for (0..max_entries + 1) |_| try store.append("posts", "{}");
    try std.testing.expectError(error.ResetRequired, store.page(arena, "posts", initial, 1));
    const checkpoint = try store.cursor(std.testing.allocator, try store.page(arena, "posts", null, 1));
    defer std.testing.allocator.free(checkpoint);
    const oversized = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.EventTooLarge, store.append("posts", oversized));
    try std.testing.expectError(error.ResetRequired, store.page(arena, "posts", checkpoint, 1));
    const before_oom = try store.cursor(std.testing.allocator, try store.page(arena, "posts", null, 1));
    defer std.testing.allocator.free(before_oom);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, store.append("posts", "{}"));
    try std.testing.expectError(error.OutOfMemory, store.append("new", "{}"));
    try std.testing.expectError(error.ResetRequired, store.page(arena, "posts", before_oom, 1));
    const unaffected = try store.page(arena, "quiet", quiet, 1);
    try std.testing.expect(!unaffected.has_next);
    try std.testing.expectEqual(@as(usize, 0), unaffected.items.len);
}

test "topic creation releases partial allocations" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var store = Store.init(allocator, std.testing.io);
            defer store.deinit();
            try store.append("posts", "{}");
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "byte budget eviction is topic-local" {
    var store = Store.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = RequestArena{ .a = fba.allocator() };
    const quiet = try store.cursor(std.testing.allocator, try store.page(arena, "quiet", null, 1));
    defer std.testing.allocator.free(quiet);
    const busy = try store.cursor(std.testing.allocator, try store.page(arena, "busy", null, 1));
    defer std.testing.allocator.free(busy);
    const frame = try std.testing.allocator.alloc(u8, max_bytes / 2 + 1);
    defer std.testing.allocator.free(frame);
    @memset(frame, 'x');
    try store.append("busy", frame);
    try store.append("busy", frame);
    try std.testing.expectEqual(@as(usize, 1), store.find("busy").?.count);
    try std.testing.expectEqual(frame.len, store.find("busy").?.bytes);
    try std.testing.expectError(error.ResetRequired, store.page(arena, "busy", busy, 1));
    _ = try store.page(arena, "quiet", quiet, 1);
}

test "full slot table retains prior generations on every replacement allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var store = Store.init(failing.allocator(), std.testing.io);
    defer store.deinit();
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = RequestArena{ .a = fba.allocator() };
    const checkpoint = try store.cursor(std.testing.allocator, try store.page(arena, "oldest", null, 1));
    defer std.testing.allocator.free(checkpoint);
    for (0..max_topics - 1) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "topic{d}", .{i});
        try store.append(name, "{}");
    }
    const generation = store.generation;
    for (0..3) |offset| {
        // Payload, ring metadata, and id allocations must all precede eviction.
        failing.fail_index = failing.alloc_index + offset;
        try std.testing.expectError(error.OutOfMemory, store.append("new", "{}"));
        try std.testing.expectEqual(generation, store.generation);
        try std.testing.expect(store.find("oldest") != null);
    }
    _ = try store.page(arena, "oldest", checkpoint, 1);
}

test "retention metadata has a fixed lazy allocation ceiling" {
    // 64-bit layout: store about 200 bytes, rings under 100 KiB in total.
    try std.testing.expect(@sizeOf(Store) <= 256);
    try std.testing.expect(@sizeOf(Topic) * max_topics <= 100 * 1024);
}

test "PostgreSQL never allocates a backfill store" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(try Store.create(failing.allocator(), std.testing.io, .postgres) == null);
    try std.testing.expectError(error.OutOfMemory, Store.create(failing.allocator(), std.testing.io, .sqlite));
    const store = (try Store.create(std.testing.allocator, std.testing.io, .sqlite)).?;
    defer store.destroy();
    try store.append("notes", "{}");
    try std.testing.expectEqual(@as(usize, 1), store.find("notes").?.count);
}
