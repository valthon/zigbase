const std = @import("std");
const ca = @import("counting_allocator.zig");

pub const Result = struct {
    name: []const u8,
    ns_median: u64,
    ns_p95: u64,
    allocs: u64,
    bytes: u64,
    buckets: [5]u64,
    peak_live: u64,
};

/// Warm up `warmup` times (JIT-free, but page/cache warm), then measure `iters`
/// timed runs. Allocation stats cover the MEASURED runs only.
///
/// Deviation from the brief: this pinned Zig (0.16.0) has no `std.time.Timer` —
/// timing goes through `std.Io.Timestamp.now(io, .awake)` instead, matching the
/// pattern already established in this repo (see `src/http_client.zig`,
/// `src/feature_cache.zig`), which is why `run` takes an `io: std.Io` param.
pub fn run(
    name: []const u8,
    warmup: usize,
    iters: usize,
    io: std.Io,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), std.mem.Allocator) anyerror!void,
) !Result {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var w: usize = 0;
    while (w < warmup) : (w += 1) try f(ctx, gpa.allocator());

    var counting = ca.CountingAllocator.init(gpa.allocator());
    const a = counting.allocator();

    const samples = try gpa.allocator().alloc(u64, iters);
    defer gpa.allocator().free(samples);

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = std.Io.Timestamp.now(io, .awake);
        try f(ctx, a);
        const t1 = std.Io.Timestamp.now(io, .awake);
        samples[i] = @intCast(t1.nanoseconds - t0.nanoseconds);
    }

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const st = counting.stats();
    return .{
        .name = name,
        .ns_median = samples[iters / 2],
        .ns_p95 = samples[(iters * 95) / 100],
        .allocs = st.allocs,
        .bytes = st.bytes,
        .buckets = st.buckets,
        .peak_live = st.peak_live,
    };
}

/// Human table by default; `--json` emits one object per line for diffing.
pub fn report(results: []const Result, json: bool, w: anytype) !void {
    if (json) {
        for (results) |r| {
            try w.print(
                "{{\"name\":\"{s}\",\"ns_median\":{d},\"ns_p95\":{d},\"allocs\":{d},\"bytes\":{d},\"peak_live\":{d},\"buckets\":[{d},{d},{d},{d},{d}]}}\n",
                .{ r.name, r.ns_median, r.ns_p95, r.allocs, r.bytes, r.peak_live, r.buckets[0], r.buckets[1], r.buckets[2], r.buckets[3], r.buckets[4] },
            );
        }
        return;
    }
    try w.print("{s:<34} {s:>10} {s:>10} {s:>8} {s:>10}  {s}\n", .{ "benchmark", "ns/op", "p95", "allocs", "bytes", "size buckets (<=64,512,4K,64K,>64K)" });
    for (results) |r| {
        try w.print("{s:<34} {d:>10} {d:>10} {d:>8} {d:>10}  {d},{d},{d},{d},{d}\n", .{
            r.name,       r.ns_median,  r.ns_p95,     r.allocs,     r.bytes,
            r.buckets[0], r.buckets[1], r.buckets[2], r.buckets[3], r.buckets[4],
        });
    }
}

test "run reports a median, a p95, and the allocation profile" {
    const Ctx = struct { n: usize };
    const F = struct {
        fn body(c: Ctx, a: std.mem.Allocator) anyerror!void {
            const buf = try a.alloc(u8, c.n);
            defer a.free(buf);
        }
    };
    const r = try run("alloc-8", 2, 10, std.testing.io, Ctx{ .n = 8 }, F.body);
    try std.testing.expectEqualStrings("alloc-8", r.name);
    try std.testing.expect(r.ns_median > 0);
    try std.testing.expect(r.ns_p95 >= r.ns_median);
    try std.testing.expectEqual(@as(u64, 10), r.allocs); // measured iters only, warmup excluded
    try std.testing.expectEqual(@as(u64, 10), r.buckets[0]);
}
