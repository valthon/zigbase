//! Bounded, process-local invalidations. Never a durable event log.
//! Also the paging primitive (`fill`) shared with the durable journal.
const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const durable = @import("durable.zig");
pub const max_topics = 16;
pub const max_entries = 256; // per topic
pub const max_bytes = 64 * 1024; // encoded frames per topic; 1 MiB total
pub const Entry = struct { sequence: u64, frame: []const u8 };
/// Raw (unauthorized) entries after a position. `next` is the last returned sequence
/// when `has_next`, else the head; `topic` and `generation` bind its sealed cursor.
pub const Page = struct { items: []const Entry, topic: []const u8, generation: u64, next: u64, has_next: bool };
pub const Position = struct { generation: u64, sequence: u64 };

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
    io: std.Io,
    /// Per-process cursor key. A cursor from another process (or before a restart)
    /// fails authentication and requires reset, as the plaintext epoch did before #496.
    key: [32]u8,
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
        var key: [32]u8 = undefined;
        io.random(&key);
        return .{ .allocator = allocator, .io = io, .key = key };
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
    /// The position a checkpoint names, or (null) a fresh checkpoint at the head,
    /// which may claim a free slot but never displaces an occupied one. A sealed
    /// cursor that does not authenticate for `id` under this process's key is reset.
    pub fn start(self: *Store, id: []const u8, checkpoint: ?[]const u8) !Position {
        if (checkpoint) |c| {
            const words = try durable.open(2, self.key, id, c);
            return .{ .generation = words[0], .sequence = words[1] };
        }
        self.lock();
        defer self.mutex.unlock();
        const topic = try self.getOrCreate(id, .free_slot_only);
        self.touch(topic);
        return .{ .generation = topic.generation, .sequence = topic.sequence };
    }
    /// Arena-scoped graph: independent frame copies survive concurrent eviction.
    /// Up to `max` of this topic's raw entries after `from`, before authorization.
    pub fn read(self: *Store, arena: RequestArena, id: []const u8, from: Position, max: usize) !Page {
        if (max == 0) return error.BadLimit;
        self.lock();
        defer self.mutex.unlock();
        const topic = self.find(id) orelse return error.ResetRequired;
        if (from.generation != topic.generation or from.sequence < topic.floor or from.sequence > topic.sequence) return error.ResetRequired;
        self.touch(topic);
        var out: std.ArrayList(Entry) = .empty;
        var more = false;
        for (0..topic.count) |offset| {
            const e = topic.entries[(topic.first + offset) % max_entries];
            if (e.sequence <= from.sequence) continue;
            if (out.items.len == max) {
                more = true;
                break;
            }
            try out.append(arena.a, .{ .sequence = e.sequence, .frame = try arena.a.dupe(u8, e.frame) });
        }
        const next = if (more) out.items[out.items.len - 1].sequence else topic.sequence;
        return .{ .items = out.items, .topic = id, .generation = topic.generation, .next = next, .has_next = more };
    }
    /// One raw page from a checkpoint (`start` then `read`); a cursorless call is an
    /// empty page at the head.
    pub fn page(self: *Store, arena: RequestArena, id: []const u8, checkpoint: ?[]const u8, limit: usize) !Page {
        if (limit == 0 or limit > 128) return error.BadLimit;
        const position = try self.start(id, checkpoint);
        if (checkpoint == null) return .{ .items = &.{}, .topic = id, .generation = position.generation, .next = position.sequence, .has_next = false };
        return self.read(arena, id, position, limit);
    }
    /// A sealed cursor: generation and sequence encrypted under this process's key,
    /// bound to the topic id. Its bytes reveal neither position, so they cannot count
    /// writes to the collection the caller may not see (#496).
    pub fn seal(self: *const Store, allocator: std.mem.Allocator, id: []const u8, position: Position) ![]u8 {
        return durable.seal(2, allocator, self.io, self.key, id, .{ position.generation, position.sequence });
    }
    pub fn cursor(self: *const Store, allocator: std.mem.Allocator, page_result: Page) ![]u8 {
        return self.seal(allocator, page_result.topic, .{ .generation = page_result.generation, .sequence = page_result.next });
    }
};

/// The result of `fill`: authorized items and where the scan ended.
pub fn Filled(comptime Item: type) type {
    return struct { items: []const Item, next: u64, has_next: bool };
}

/// Fills a page with up to `limit` AUTHORIZED items, scanning raw entries after
/// `after` in chunks of at most `chunk`, and examining at most `budget` entries.
///
/// `source.fetch(arena, after, max) !Page`-shaped: raw entries after `after`, at
/// most `max`, with `next` (the head when `!has_next`). `authorizer.deliver(scratch,
/// entry) !?Item`: the caller's item, allocated on its own request arena, or null
/// when the caller may not see the entry. `scratch` dies with the chunk.
///
/// Observable output depends only on authorized entries (#501): `items` are the first
/// `limit` the caller may see; `has_next` is whether one more exists (it is looked
/// up, never inferred from hidden entries), and `next` resumes after the last item or,
/// when none follow, at the source's head. Only exhausting `budget` ends a page on
/// hidden entries: then `has_next` is true and `next` resumes after the examined ones.
/// A source that bounds its head (`durable.scan_budget` at or above the retained
/// entries; the local store's ring) cannot exhaust it.
///
/// Contract 4: the items graph (each item and the list) is request-scoped, allocated
/// on `arena` and freed with it; per-chunk raw copies use a child arena reset per chunk.
pub fn fill(comptime Item: type, arena: RequestArena, source: anytype, authorizer: anytype, after: u64, limit: usize, budget: usize, chunk: usize) !Filled(Item) {
    std.debug.assert(limit > 0 and budget > 0 and chunk > 0);
    var items: std.ArrayList(Item) = .empty;
    errdefer items.deinit(arena.a);
    var scratch = std.heap.ArenaAllocator.init(arena.a);
    defer scratch.deinit();
    var position = after; // every entry at or before this has been examined
    var last_item = after;
    var examined: usize = 0;
    while (true) {
        _ = scratch.reset(.retain_capacity);
        const got = try source.fetch(RequestArena.from(&scratch), position, @min(chunk, budget - examined));
        std.debug.assert(got.items.len > 0 or !got.has_next);
        for (got.items) |entry| {
            examined += 1;
            if (try authorizer.deliver(scratch.allocator(), entry)) |item| {
                if (items.items.len == limit) return .{ .items = try items.toOwnedSlice(arena.a), .next = last_item, .has_next = true };
                try items.append(arena.a, item);
                last_item = entry.sequence;
            }
            position = entry.sequence;
        }
        if (!got.has_next) return .{ .items = try items.toOwnedSlice(arena.a), .next = got.next, .has_next = false };
        if (examined == budget) return .{ .items = try items.toOwnedSlice(arena.a), .next = position, .has_next = true };
    }
}

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

/// Test source over a fixed entry list; `head` is the position after the last entry.
const FakeSource = struct {
    entries: []const Entry,
    head: u64,
    pub fn fetch(self: FakeSource, arena: RequestArena, after: u64, max: usize) !Page {
        var out: std.ArrayList(Entry) = .empty;
        var more = false;
        for (self.entries) |e| {
            if (e.sequence <= after) continue;
            if (out.items.len == max) {
                more = true;
                break;
            }
            try out.append(arena.a, e);
        }
        return .{ .items = out.items, .topic = "t", .generation = 1, .next = if (more) out.items[out.items.len - 1].sequence else self.head, .has_next = more };
    }
};

/// Test authorizer: the caller sees only frames reading "mine".
const MineOnly = struct {
    pub fn deliver(_: MineOnly, _: std.mem.Allocator, e: Entry) !?u64 {
        return if (std.mem.eql(u8, e.frame, "mine")) e.sequence else null;
    }
};

const Outcome = struct { items: usize, has_next: bool };

/// Every page a caller gets paging `frames` from the start at `limit`.
fn pagesOver(frames: []const []const u8, limit: usize, budget: usize, chunk: usize, out: []Outcome) ![]Outcome {
    var entries: [32]Entry = undefined;
    for (frames, 0..) |frame, i| entries[i] = .{ .sequence = i + 1, .frame = frame };
    const source = FakeSource{ .entries = entries[0..frames.len], .head = frames.len };
    var after: u64 = 0;
    var n: usize = 0;
    while (true) : (n += 1) {
        const filled = try fill(u64, RequestArena.forTest(std.testing.allocator), source, MineOnly{}, after, limit, budget, chunk);
        defer std.testing.allocator.free(filled.items);
        for (filled.items) |sequence| try std.testing.expect(sequence > after);
        out[n] = .{ .items = filled.items.len, .has_next = filled.has_next };
        after = filled.next;
        if (!filled.has_next) return out[0 .. n + 1];
    }
}

test "fill: items, hasNext and page count do not depend on hidden entries (#501)" {
    var one_buf: [32]Outcome = undefined;
    var three_buf: [32]Outcome = undefined;
    // Hidden entries before, between and after the caller's own two entries.
    const one = try pagesOver(&.{ "h", "mine", "h", "mine", "h" }, 1, 64, 2, &one_buf);
    const three = try pagesOver(&.{ "h", "h", "h", "mine", "h", "h", "h", "mine", "h", "h", "h" }, 1, 64, 2, &three_buf);
    try std.testing.expectEqualSlices(Outcome, &.{ .{ .items = 1, .has_next = true }, .{ .items = 1, .has_next = false } }, one);
    try std.testing.expectEqualSlices(Outcome, one, three);
    // Only hidden entries: one empty page, however many there are.
    const none = try pagesOver(&.{ "h", "h", "h", "h", "h" }, 1, 64, 1, &one_buf);
    try std.testing.expectEqualSlices(Outcome, &.{.{ .items = 0, .has_next = false }}, none);
    // A full page whose remaining entries are hidden ends the stream.
    const full = try pagesOver(&.{ "mine", "h", "h" }, 1, 64, 1, &one_buf);
    try std.testing.expectEqualSlices(Outcome, &.{.{ .items = 1, .has_next = false }}, full);
}

test "fill: an exhausted scan budget resumes after the examined entries" {
    var buf: [32]Outcome = undefined;
    // The residual the budget allows: 5 hidden entries over a budget of 2 end two pages early.
    const pages = try pagesOver(&.{ "h", "h", "h", "h", "h", "mine" }, 1, 2, 1, &buf);
    try std.testing.expectEqualSlices(Outcome, &.{ .{ .items = 0, .has_next = true }, .{ .items = 0, .has_next = true }, .{ .items = 1, .has_next = false } }, pages);
    // A budget that covers the source never ends a page on hidden entries.
    const complete = try pagesOver(&.{ "h", "h", "h", "h", "h", "mine" }, 1, 6, 1, &buf);
    try std.testing.expectEqualSlices(Outcome, &.{.{ .items = 1, .has_next = false }}, complete);
}

test "fill: allocation failure leaks nothing" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const entries = [_]Entry{ .{ .sequence = 1, .frame = "mine" }, .{ .sequence = 2, .frame = "h" }, .{ .sequence = 3, .frame = "mine" } };
            const filled = try fill(u64, RequestArena.forTest(allocator), FakeSource{ .entries = &entries, .head = 3 }, MineOnly{}, 0, 2, 8, 1);
            allocator.free(filled.items);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "local cursors are sealed: same shape at any position, bound to topic and process (#496)" {
    const a = std.testing.allocator;
    var store = Store.init(a, std.testing.io);
    defer store.deinit();
    var other = Store.init(a, std.testing.io);
    defer other.deinit();
    const once = try store.seal(a, "notes", .{ .generation = 2, .sequence = 1 });
    defer a.free(once);
    const twice = try store.seal(a, "notes", .{ .generation = 2, .sequence = 2 });
    defer a.free(twice);
    const again = try store.seal(a, "notes", .{ .generation = 2, .sequence = 1 });
    defer a.free(again);
    try std.testing.expectEqual(once.len, twice.len);
    for (once) |c| try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
    try std.testing.expect(!std.mem.eql(u8, once, again)); // fresh nonce per cursor
    try std.testing.expectEqual(Position{ .generation = 2, .sequence = 1 }, try store.start("notes", once));
    try std.testing.expectEqual(Position{ .generation = 2, .sequence = 2 }, try store.start("notes", twice));
    try std.testing.expectError(error.ResetRequired, store.start("other", once));
    try std.testing.expectError(error.ResetRequired, other.start("notes", once));
    try std.testing.expectError(error.ResetRequired, store.start("notes", "stale:1"));
}
