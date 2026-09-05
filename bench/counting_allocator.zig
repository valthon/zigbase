const std = @import("std");

const Alignment = std.mem.Alignment;

pub const Stats = struct {
    allocs: u64 = 0,
    bytes: u64 = 0,
    /// [<=64B, <=512B, <=4K, <=64K, >64K] — distinguishes one large allocation
    /// from thousands of small ones, which byte totals hide.
    buckets: [5]u64 = .{0} ** 5,
    peak_live: u64 = 0,
};

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    st: Stats = .{},
    live: u64 = 0,

    pub fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    pub fn stats(self: *const CountingAllocator) Stats {
        return self.st;
    }

    pub fn requireEmpty(self: *const CountingAllocator) error{LiveAllocations}!void {
        if (self.live != 0) return error.LiveAllocations;
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = vAlloc,
        .resize = vResize,
        .remap = vRemap,
        .free = vFree,
    };

    fn bucketOf(len: usize) usize {
        if (len <= 64) return 0;
        if (len <= 512) return 1;
        if (len <= 4096) return 2;
        if (len <= 65536) return 3;
        return 4;
    }

    fn vAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.st.allocs += 1;
        self.st.bytes += len;
        self.st.buckets[bucketOf(len)] += 1;
        self.live += len;
        if (self.live > self.st.peak_live) self.st.peak_live = self.live;
        return p;
    }

    fn vResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
        self.live = self.live + new_len - memory.len;
        if (self.live > self.st.peak_live) self.st.peak_live = self.live;
        return true;
    }

    fn vRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.live = self.live + new_len - memory.len;
        if (self.live > self.st.peak_live) self.st.peak_live = self.live;
        return p;
    }

    fn vFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
        self.live -= memory.len;
    }
};

test "counts allocations into size buckets and tracks peak live bytes" {
    var c = CountingAllocator.init(std.testing.allocator);
    const a = c.allocator();

    const small = try a.alloc(u8, 8); // bucket 0
    const big = try a.alloc(u8, 100_000); // bucket 4
    try std.testing.expectError(error.LiveAllocations, c.requireEmpty());
    a.free(small);
    a.free(big);
    try c.requireEmpty();

    const s = c.stats();
    try std.testing.expectEqual(@as(u64, 2), s.allocs);
    try std.testing.expectEqual(@as(u64, 100_008), s.bytes);
    try std.testing.expectEqual(@as(u64, 1), s.buckets[0]);
    try std.testing.expectEqual(@as(u64, 1), s.buckets[4]);
    try std.testing.expectEqual(@as(u64, 100_008), s.peak_live);
}
