const std = @import("std");
const zb = @import("zigbase");
var gate: std.atomic.Value(bool) = .init(false);
var entered: std.atomic.Value(u32) = .init(0);
var completed: std.atomic.Value(u32) = .init(0);

fn job(ctx: *zb.Ctx, _: *zb.events.JobEvent) !void {
    _ = entered.fetchAdd(1, .release);
    while (!gate.load(.acquire)) try ctx.app.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
    _ = completed.fetchAdd(1, .release);
}
fn enqueue(req: *zb.Req(void)) zb.RouteError!void {
    req.ctx.app.submit("one", job) catch return error.RouteFailed;
    req.ctx.app.submit("two", job) catch return error.RouteFailed;
}
fn release(_: *zb.Req(void)) zb.RouteError!void {
    gate.store(true, .release);
}
fn state(_: *zb.Req(void)) zb.RouteError!struct { entered: u32, completed: u32 } {
    return .{ .entered = entered.load(.acquire), .completed = completed.load(.acquire) };
}
pub fn main(init: std.process.Init) !void {
    return zb.App(.{
        .pools = .{ .jobs = 8, .memory_jobs = 1, .stack_size = 2 << 20 },
        .routes = .{
            .{ .method = .POST, .path = "/api/test-jobs/enqueue", .handler = enqueue, .auth = .public },
            .{ .method = .POST, .path = "/api/test-jobs/release", .handler = release, .auth = .public },
            .{ .method = .GET, .path = "/api/test-jobs/state", .handler = state, .auth = .public },
        },
    }).runCli(init);
}
