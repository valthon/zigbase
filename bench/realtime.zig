//! Shared WS/SSE authorization seam, not a socket throughput benchmark.
//! Setup and collection-cache warming are excluded; auth is reverified on EVERY delivery.
const std = @import("std");
const zb = @import("zigbase");
const i = zb.internal;
const counting = @import("counting_allocator.zig");
const harness = @import("harness.zig");
const Conn = i.realtime_connection.Conn;

fn guard(ctx: *zb.Ctx, _: []const u8) bool {
    return ctx.rctx.auth != null;
}

/// All setup allocations are scoped to this call. Result names are static literals.
pub fn run(alloc: std.mem.Allocator, io: std.Io, results: *std.ArrayList(harness.Result)) !void {
    var nonce: [12]u8 = undefined;
    io.random(&nonce);
    const directory = try std.fmt.allocPrint(alloc, "/tmp/zigbase-fanout-{x}", .{nonce});
    defer alloc.free(directory);
    try std.Io.Dir.cwd().createDir(io, directory, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch |err| std.log.err("benchmark cleanup: {s}", .{@errorName(err)});
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}/bench.db", .{directory}, 0);
    defer alloc.free(path);
    var pool = try i.db.Pool.init(alloc, io, path);
    defer pool.deinit();
    {
        const writer = pool.acquireWriter();
        defer pool.releaseWriter();
        try i.migrations.run(writer);
        const users = try i.collections.create(alloc, io, writer, .{ .id = "", .name = "principals", .type = .auth, .fields = &.{} });
        defer users.deinit(alloc);
        try writer.exec("INSERT INTO principals (id,created,updated,email,passwordHash,tokenKey,verified) VALUES ('u1','','','bench@example.test','','bench-key',1);");
        const fields = [_]i.schema.Field{
            .{ .id = "owner", .name = "owner", .options = .{ .text = .{} } },
            .{ .id = "account", .name = "account", .options = .{ .text = .{} } },
        };
        inline for (.{ "public_posts", "owned_posts", "tenant_posts" }) |name| {
            const col = try i.collections.create(alloc, io, writer, .{
                .id = "",
                .name = name,
                .fields = &fields,
                .viewRule = if (std.mem.eql(u8, name, "owned_posts")) "owner = @request.auth.id" else "@public",
                .options = .{ .tenant_field = if (std.mem.eql(u8, name, "tenant_posts")) "account" else null },
            });
            defer col.deinit(alloc);
            try writer.exec("INSERT INTO " ++ name ++ " (id,created,updated,owner,account) VALUES ('r1','','','u1','accA');");
        }
    }
    var cache = i.colcache.Cache.init(alloc);
    defer cache.deinit();
    var dispatch = i.events.Dispatch{ .realtime_can_subscribe = guard };
    var app = i.app.App{ .allocator = alloc, .io = io, .pool = &pool, .jwt_secret = "benchmark-only", .col_cache = &cache, .dispatch = &dispatch };
    const key = zb.crypto.deriveKey(app.jwt_secret, "bench-key");
    const token = try zb.jwt.sign(alloc, .{ .id = "u1", .collection = "principals", .type = .auth, .iat = 0, .exp = 9999999999 }, &key);
    defer alloc.free(token);
    // The retained record is deliberately empty: production delivery must replace it
    // with the freshly verified physical auth record, never trust cached identity data.
    const authenticated = Conn{ .auth = .{ .record = .null, .is_superuser = false, .exp = 9999999999, .token = token } };
    const cases = [_]struct { name: []const u8, conn: Conn }{
        .{ .name = "public_posts", .conn = .{} },
        .{ .name = "owned_posts", .conn = authenticated },
        .{ .name = "tenant_posts", .conn = blk: {
            var c = authenticated;
            c.tenancy_enabled = true;
            c.account_id = "accA";
            break :blk c;
        } },
        .{ .name = "private_topic", .conn = authenticated },
    };
    // Prove the tenant fixture actually constrains delivery before timing it.
    // This is a retained account scope, not a benchmark of membership resolution.
    var wrong_tenant = authenticated;
    wrong_tenant.tenancy_enabled = true;
    wrong_tenant.account_id = "accB";
    if (i.realtime_hub.frameForDelivery(alloc, &app, &wrong_tenant, null, "tenant_posts", "{\"action\":\"update\",\"record\":{\"id\":\"r1\"}}") != null)
        return error.CrossTenantDelivery;
    for (cases) |case| {
        for ([_]usize{ 1024, 10240 }) |payload_size| {
            const payload = try alloc.alloc(u8, payload_size);
            defer alloc.free(payload);
            @memset(payload, 'x');
            const message = try std.fmt.allocPrint(alloc, "{{\"action\":\"update\",\"record\":{{\"id\":\"r1\",\"body\":\"{s}\"}}}}", .{payload});
            defer alloc.free(message);
            for ([_]usize{ 1, 10, 100, 1000 }) |fanout| {
                // Distinct retained connection structs, one principal. Subscription lookup
                // and transport writes are outside the measured delivery callback.
                const subscribers = try alloc.alloc(Conn, fanout);
                defer alloc.free(subscribers);
                @memset(subscribers, case.conn);
                for (0..2) |_| try deliver(alloc, &app, subscribers, case.name, message);
                var meter = counting.CountingAllocator.init(alloc);
                var samples: [20]u64 = undefined;
                for (&samples) |*sample| {
                    const begin = std.Io.Timestamp.now(io, .awake);
                    try deliver(meter.allocator(), &app, subscribers, case.name, message);
                    sample.* = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds - begin.nanoseconds);
                    try meter.requireEmpty();
                }
                std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
                const stats = meter.stats();
                try results.append(alloc, .{
                    .name = case.name,
                    .ns_median = samples[10],
                    .ns_p95 = samples[18],
                    .ns_max = samples[19],
                    .allocs = stats.allocs,
                    .bytes = stats.bytes,
                    .buckets = stats.buckets,
                    .peak_live = stats.peak_live,
                    .iterations = samples.len,
                    .subscribers = fanout,
                    .payload_bytes = payload_size,
                });
            }
        }
    }
}

fn deliver(alloc: std.mem.Allocator, app: *i.app.App, subscribers: []const Conn, channel: []const u8, message: []const u8) !void {
    for (subscribers) |*subscriber| {
        const frame = i.realtime_hub.frameForDelivery(alloc, app, subscriber, null, channel, message) orelse return error.UnexpectedAuthorizationDenial;
        defer if (frame.ptr != message.ptr) alloc.free(frame);
        // Update/custom frames must be forwarded verbatim, not allocated per subscriber.
        if (frame.ptr != message.ptr or frame.len != message.len) return error.UnexpectedFrameCopy;
        std.mem.doNotOptimizeAway(frame);
    }
}
